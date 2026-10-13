# frozen_string_literal: true

require "rails_helper"

# Settled-only packet: requires root model/configure/read snippets and migration8.
# All audit assertions are native receiver bookkeeping, not CMS qualification.
describe DiscussionBridge::CmsAuthorityLifecycle do
  fab!(:admin)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, user: admin, category: category) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    @queued = []
    @collector = ->(args) { @queued << args.deep_dup }
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(
      :wake_connection,
    ).and_wrap_original do |method, id, **options|
      method.call(id, **options.merge(enqueuer: @collector))
    end
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.login_required = false
    SiteSetting.force_https = true
    @now = Time.current
    @connection, @secret = native_connection("Native authority author fixture")
    @configuration = input_configuration
    configure(@connection, @configuration)
    @store = DiscussionBridge::CmsSourceStore.new(@connection, clock: -> { @now })
    @store.refresh_all!
    @mapping = mapping_fixture(@connection, topic)
    @coordinator = DiscussionBridge::CmsWorkCoordinator.new(@connection, clock: -> { @now })
    @work =
      @coordinator.enqueue!(@mapping, source_snapshot: @store.capture_snapshot(topic).metadata)
    @lease =
      @coordinator.claim(
        "mutation_id" => SecureRandom.uuid,
        "mapping_id" => @mapping.mapping_id,
      ).body
    @checkpoint = @store.feed("stream" => "initial").body.fetch("checkpoint_cursor")
    DiscussionBridge::CmsMappingReadStore.new(@connection, clock: -> { @now }).inventory
    @queued.clear
  end

  def native_connection(name)
    DiscussionBridgeContentConnection.issue!(
      name: name,
      platform: "ghost",
      allowed_origins: ["https://site.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: ["news"],
    )
  end

  def input_configuration
    {
      "profile" => "ghost",
      "destination_origin" => "https://site.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "authority-fixture:1",
        "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic",
        "complete_content_supported" => true,
      },
      "policy" => {
        "enabled" => true,
        "selection" => "all_public",
        "category_ids" => [],
        "include_topic_ids" => [],
        "exclude_topic_ids" => [],
        "include_unlisted" => false,
        "publication_kind" => "dynamic",
        "presentation_mode" => "simple",
        "author_ids" => [],
        "taxonomy_ids" => [],
        "existing_record_adoption" => "disabled",
        "adoptable_resource_ids" => [],
      },
    }
  end

  def configure(connection, configuration)
    DiscussionBridge::CmsAuthorityStore.new(connection).configure!(
      actor: admin,
      input: {
        "expected_policy_revision" =>
          connection.reload.cms_configuration&.dig("policy", "policy_revision"),
        "configuration" => configuration,
      },
    )
    connection.reload
  end

  # Deliberately labelled native ID: receiver identity fixture only, no remote
  # Ghost object, external ownership lock or public output proof is claimed.
  def mapping_fixture(connection, source_topic)
    record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: connection.id,
        topic_id: source_topic.id,
        external_id: "authority-#{source_topic.id}",
        canonical_url: "https://site.example/authority-#{source_topic.id}/",
        lane: "news",
        native_materialization: true,
        presentation_mode: "simple",
      ).record
    DiscussionBridgeCmsMapping.create!(
      mapping_id: SecureRandom.uuid,
      content_connection: connection,
      content_binding: record.active_binding("presentation"),
      source_id: "topic:#{source_topic.id}",
      mapping_revision: SecureRandom.uuid,
      destination_native_id: "fixture:native:authority:#{source_topic.id}",
    )
  end

  def stream
    DiscussionBridgeCmsSourceStream.find_by!(
      content_connection_id: @connection.id,
      publication_lane: "news",
    )
  end

  def rejected(code, &block)
    expect(&block).to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq(code)
    }
  end

  def configuration_events
    DB.query_single(
      "SELECT count(*) FROM discussion_bridge_cms_configuration_events WHERE content_connection_id = ?",
      @connection.id,
    ).first
  end

  def audit
    DiscussionBridgeCmsScopeEvent.where(content_connection_id: @connection.id).order(:id).last
  end

  def current_bookkeeping
    {
      "configuration" => @connection.reload.cms_configuration.deep_dup,
      "work" => @work.reload.attributes.deep_dup,
      "mapping" => @mapping.reload.attributes.deep_dup,
      "stream" => stream.attributes.deep_dup,
      "source_cursors" =>
        DiscussionBridgeCmsSourceCursor.order(:id).map { |row| row.attributes.deep_dup },
      "read_snapshots" =>
        DiscussionBridgeCmsReadSnapshot.order(:id).map { |row| row.attributes.deep_dup },
    }
  end

  {
    "enabled" => false,
    "platform" => "hugo",
    "allowed_origins" => ["https://other.example"],
    "allowed_directions" => ["to_discourse"],
    "allowed_lanes" => ["other"],
  }.each do |field, value|
    it "atomically invalidates actual raw #{field} writes without locking dirty self or translating CMS selections" do
      before = @connection.cms_configuration.deep_dup
      old_scope = stream.source_scope_revision
      cursor_payloads = DiscussionBridgeCmsSourceCursor.order(:id).pluck(:id, :page_body)
      @connection.assign_attributes(field => value)
      expect(@connection.changed?).to eq(true)
      @connection.save!
      after = @connection.reload.cms_configuration
      expect(after.fetch("policy").fetch("policy_revision")).not_to eq(
        before.dig("policy", "policy_revision"),
      )
      expect(after.except("policy")).to eq(before.except("policy"))
      expect(after.fetch("policy").except("policy_revision")).to eq(
        before.fetch("policy").except("policy_revision"),
      )
      expect(stream.source_scope_revision).to eq(old_scope + 1)
      expect(@work.reload.state).to eq("cancelled")
      expect(@work.lease_verifier).to be_nil
      expect(@work.attempt).to eq(1)
      expect(@mapping.reload.fence_generation).to eq(@lease.fetch("lease_generation"))
      expect(DiscussionBridgeCmsSourceCursor.where(invalidated_at: nil)).to be_empty
      expect(DiscussionBridgeCmsReadSnapshot.where(invalidated_at: nil)).to be_empty
      expect(DiscussionBridgeCmsSourceCursor.order(:id).pluck(:id, :page_body)).to eq(
        cursor_payloads,
      )
      expect(audit.actor_user_id).to be_nil
      expect(audit.event_origin).to eq("native_model_scope_mutation")
      expect(audit.changed_fields).to eq([field])
      expect(audit.values).to eq(field => value)
      expect(JSON.generate(audit.attributes)).not_to include(
        @secret,
        @connection.secret_digest,
        "lease_token",
        "content_html",
      )
      expect(@queued).to be_empty
    end
  end

  it "uses stored untouched scope and CMS selections when a stale model writes a different field" do
    stale = DiscussionBridgeContentConnection.find(@connection.id)
    @connection.update!(allowed_origins: %w[https://site.example https://second.example])
    current = input_configuration
    current.fetch("policy")["include_unlisted"] = true
    configure(@connection, current)
    stored = @connection.cms_configuration.deep_dup
    stale.update!(allowed_lanes: %w[news other])
    @connection.reload
    expect(@connection.allowed_origins).to eq(%w[https://site.example https://second.example])
    expect(@connection.cms_configuration.fetch("policy").except("policy_revision")).to eq(
      stored.fetch("policy").except("policy_revision"),
    )
    expect(audit.changed_fields).to eq(["allowed_lanes"])
    expect(audit.previous_values).to eq("allowed_lanes" => ["news"])
    expect(@work.reload.state).to eq("superseded")
  end

  it "preserves work, proofs, attempts, cursors and policy on no-op, descriptive and actual secret rotation saves" do
    @mapping.update!(
      prepared_transaction: {
        "fixture" => "native recovery proof",
      },
      verified_result: {
        "fixture" => "historical public receipt",
      },
    )
    retained = current_bookkeeping
    initial_audits = DiscussionBridgeCmsScopeEvent.count
    @connection.update!(allowed_origins: @connection.allowed_origins.deep_dup)
    @connection.update!(
      name: "Renamed authority fixture",
      adapter_id: "fixture-adapter",
      adapter_version: "fixture-version",
      last_seen_at: @now,
    )
    secret = @connection.rotate_secret!
    expect(current_bookkeeping).to eq(retained)
    expect(DiscussionBridgeCmsScopeEvent.count).to eq(initial_audits)
    expect(@queued).to be_empty
    expect(@connection.authenticate_secret?(@secret)).to eq(false)
    expect(@connection.authenticate_secret?(secret)).to eq(true)
  end

  it "rejects a previously authenticated digest after real rotation and permits otherwise-current new credentials" do
    old_digest = @connection.secret_digest
    old_request =
      DiscussionBridge::CmsWorkCoordinator.new(@connection, authenticated_secret_digest: old_digest)
    @connection.rotate_secret!
    rejected("authentication_failed") { old_request.query(@work.work_id) }
    new_request =
      DiscussionBridge::CmsWorkCoordinator.new(
        @connection,
        authenticated_secret_digest: @connection.reload.secret_digest,
      )
    expect(new_request.query(@work.work_id).status).to eq(200)
    expect(@work.reload.state).to eq("leased")
    expect(@work.attempt).to eq(1)
  end

  it "preserves retained pending, retry, attention and terminal state rows during actual digest rotation" do
    # State-storage fixtures, not claims of successful native CMS/public work.
    retained =
      %w[pending retry_wait attention verified].map do |state|
        source_topic = Fabricate(:topic, user: admin, category: category)
        Fabricate(:post, topic: source_topic, user: admin, post_number: 1)
        mapping = mapping_fixture(@connection, source_topic)
        work =
          @coordinator.enqueue!(
            mapping,
            source_snapshot: @store.capture_snapshot(source_topic).metadata,
          )
        work.update!(
          state: state,
          attempt: state == "attention" ? 3 : 1,
          retry_at: state == "retry_wait" ? @now + 30 : nil,
          last_failure_code: state == "attention" ? "public_verification_failed" : nil,
        )
        [work.id, work.reload.attributes.deep_dup]
      end
    @queued.clear
    policy = @connection.reload.cms_configuration.deep_dup
    @connection.rotate_secret!
    retained.each do |id, attributes|
      expect(DiscussionBridgeCmsWork.find(id).attributes).to eq(attributes)
    end
    expect(@connection.reload.cms_configuration).to eq(policy)
    expect(@queued).to be_empty
  end

  it "records the actual validated native administrator and rejects a supplied nonadministrator" do
    described_class.admin_update!(
      connection_id: @connection.id.to_s,
      attributes: {
        allowed_lanes: %w[news other],
      },
      actor: admin,
    )
    expect(audit.actor_user_id).to eq(admin.id)
    expect(audit.event_origin).to eq("native_admin_scope_mutation")
    count = DiscussionBridgeCmsScopeEvent.count
    nonadmin = Fabricate(:user)
    expect {
      described_class.admin_update!(
        connection_id: @connection.id,
        attributes: {
          enabled: false,
        },
        actor: nonadmin,
      )
    }.to raise_error(Discourse::InvalidAccess)
    expect(@connection.reload.enabled).to eq(true)
    expect(DiscussionBridgeCmsScopeEvent.count).to eq(count)
    expect {
      described_class.admin_update!(
        connection_id: @connection.id,
        attributes: {
          actor_user_id: nonadmin.id,
        },
        actor: admin,
      )
    }.to raise_error(ArgumentError)
  end

  it "rolls a native scope transaction back with its invalidation and defers no wake" do
    retained = current_bookkeeping
    initial_audits = DiscussionBridgeCmsScopeEvent.count
    expect do
      DiscussionBridgeContentConnection.transaction do
        @connection.update!(allowed_lanes: %w[news other])
        raise "native scope writer rolled back"
      end
    end.to raise_error(RuntimeError, "native scope writer rolled back")
    expect(current_bookkeeping).to eq(retained)
    expect(@connection.reload.allowed_lanes).to eq(["news"])
    expect(DiscussionBridgeCmsScopeEvent.count).to eq(initial_audits)
    expect(@queued).to be_empty
  end

  it "rolls scope, revision and cursor/work invalidation back if the native audit cannot save" do
    retained = current_bookkeeping
    allow(DiscussionBridgeCmsScopeEvent).to receive(:create!).and_raise(
      "native audit storage failure",
    )
    expect { @connection.update!(enabled: false) }.to raise_error(
      RuntimeError,
      "native audit storage failure",
    )
    expect(current_bookkeeping).to eq(retained)
    expect(@connection.reload.enabled).to eq(true)
    expect(@queued).to be_empty
  end

  it "rejects a compound raw scope and CMS-selection replacement instead of overwriting stored selections" do
    retained = current_bookkeeping
    replacement = @connection.cms_configuration.deep_dup
    replacement.fetch("policy")["include_unlisted"] = true
    expect {
      @connection.update!(allowed_lanes: %w[news other], cms_configuration: replacement)
    }.to raise_error(ActiveRecord::RecordInvalid)
    expect(current_bookkeeping).to eq(retained)
    expect(@queued).to be_empty
  end

  it "allows native disable of malformed stored CMS configuration without repair or fake revision" do
    malformed = {
      "policy" => ["unusable retained native state"],
      "retained" => {
        "selection" => "not authority",
      },
    }
    @connection.update!(cms_configuration: malformed)
    old_scope = stream.source_scope_revision
    @connection.update!(enabled: false)
    expect(@connection.reload.enabled).to eq(false)
    expect(@connection.cms_configuration).to eq(malformed)
    expect(@work.reload.state).to eq("cancelled")
    expect(stream.source_scope_revision).to eq(old_scope + 1)
    expect(audit.previous_policy_revision).to be_nil
    expect(audit.policy_revision).to be_nil
    expect(DiscussionBridgeCmsReadSnapshot.where(invalidated_at: nil)).to be_empty
    expect(@queued).to be_empty
  end

  it "also rolls malformed-configuration disable and its invalidation back atomically" do
    malformed = { "policy" => "malformed retained state" }
    @connection.update!(cms_configuration: malformed)
    retained = current_bookkeeping
    expect do
      DiscussionBridgeContentConnection.transaction do
        @connection.update!(enabled: false)
        raise "malformed disable writer rolled back"
      end
    end.to raise_error(RuntimeError, "malformed disable writer rolled back")
    expect(current_bookkeeping).to eq(retained)
    expect(@connection.reload.enabled).to eq(true)
    expect(@queued).to be_empty
  end

  it "invalidates exactly once on actual CAS configure change and preserves the exact no-op and conflict branches" do
    old_scope = stream.source_scope_revision
    old_count = configuration_events
    configuration = input_configuration
    configuration.fetch("policy")["include_unlisted"] = true
    configure(@connection, configuration)
    revision = @connection.cms_configuration.dig("policy", "policy_revision")
    expect(stream.source_scope_revision).to eq(old_scope + 1)
    expect(configuration_events).to eq(old_count + 1)
    expect(@work.reload.state).to eq("superseded")
    @queued.clear
    configure(@connection, configuration)
    expect(stream.source_scope_revision).to eq(old_scope + 1)
    expect(@connection.cms_configuration.dig("policy", "policy_revision")).to eq(revision)
    expect(configuration_events).to eq(old_count + 1)
    expect(@queued).to be_empty
    rejected("revision_conflict") do
      DiscussionBridge::CmsAuthorityStore.new(@connection).configure!(
        actor: admin,
        input: {
          "expected_policy_revision" => SecureRandom.uuid,
          "configuration" => configuration,
        },
      )
    end
    expect(stream.source_scope_revision).to eq(old_scope + 1)
  end

  it "permits a first native CMS save to explicitly enable without an enrollment or prerequisite off-save" do
    connection, = native_connection("Explicit first-save enable fixture")
    expect(connection.cms_configuration).to be_nil
    configure(connection, input_configuration)
    expect(connection.reload.cms_configuration.dig("policy", "enabled")).to eq(true)
    expect(@queued.any? { |args| args[:connection_id] == connection.id.to_s }).to eq(true)
    expect(
      DiscussionBridgeCmsSourceIntent.joins(:cms_source_stream).where(
        discussion_bridge_cms_source_streams: {
          content_connection_id: connection.id,
        },
      ),
    ).to be_empty
  end

  it "does not resurrect an old lease or source cursor when a raw origin is removed and restored" do
    old_revision = @connection.cms_configuration.dig("policy", "policy_revision")
    lease_verifier = @work.reload.lease_verifier
    generation = @mapping.reload.fence_generation
    @connection.update!(allowed_origins: ["https://other.example"])
    @connection.update!(allowed_origins: ["https://site.example"])
    @now -= 1.day
    rejected("cursor_scope_changed") { @store.feed("stream" => "changes", "cursor" => @checkpoint) }
    expect(@connection.reload.cms_configuration.dig("policy", "policy_revision")).not_to eq(
      old_revision,
    )
    expect(@work.reload.state).to eq("cancelled")
    expect(@work.lease_verifier).to be_nil
    expect(lease_verifier).not_to be_nil
    expect(@work.attempt).to eq(1)
    expect(@mapping.reload.fence_generation).to eq(generation)
  end

  def history_cursor(connection, mapping)
    101.times do |index|
      DiscussionBridgeCmsUrlHistoryEntry.create!(
        cms_mapping_id: mapping.id,
        url: "https://site.example/retired-#{mapping.id}-#{index}/",
        retired_at: @now,
        move_id: SecureRandom.uuid,
        created_at: @now,
      )
    end
    DiscussionBridge::CmsMappingReadStore
      .new(connection, clock: -> { @now })
      .url_history(mapping.mapping_id)
      .body
      .fetch("next_cursor")
  end

  def catalog_scope_fixture(connection)
    catalog =
      DiscussionBridge::CmsCatalogStore.new(
        connection,
        clock: -> { @now },
        authenticated_secret_digest: connection.reload.secret_digest,
      )
    begin_input = {
      "mutation_id" => SecureRandom.uuid,
      "kind" => "authors",
      "native_revision" => "native-catalog-scope-fixture:1",
      "total_items" => 101,
    }
    upload = catalog.begin_upload(begin_input).body.fetch("upload_id")
    items =
      101.times.map do |index|
        {
          "id" => "native-author-#{index}",
          "label" => "Native author #{index}",
          "available" => true,
        }
      end
    items
      .each_slice(100)
      .with_index do |slice, number|
        catalog.append_page(
          upload,
          "mutation_id" => SecureRandom.uuid,
          "page" => number,
          "items" => slice,
        )
      end
    result =
      catalog.finalize(
        upload,
        {
          "mutation_id" => SecureRandom.uuid,
          "upload_id" => upload,
          "expected_total_items" => 101,
        },
      )
    token = result.body.fetch("next_cursor")
    open_id =
      catalog
        .begin_upload(begin_input.merge("mutation_id" => SecureRandom.uuid, "total_items" => 1))
        .body
        .fetch("upload_id")
    cursor =
      DiscussionBridgeCmsCatalogCursor.find_by!(token_digest: Digest::SHA256.hexdigest(token))
    open_upload = DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: open_id)
    [catalog, token, cursor, open_upload, items.last]
  end

  it "preserves real catalog cursors/uploads across policy selections, off, exact no-op and descriptive capabilities" do
    catalog, token, cursor, upload, last_item = catalog_scope_fixture(@connection)
    cursor_scope = cursor.scope_signature
    upload_scope = upload.scope_signature
    expiry = upload.expires_at
    source_scope = stream.source_scope_revision
    configuration = input_configuration
    configuration.fetch("policy")["author_ids"] = ["native-author-0"]
    configure(@connection, configuration)
    expect(stream.source_scope_revision).to eq(source_scope + 1)
    configuration.fetch("policy")["enabled"] = false
    configure(@connection, configuration)
    off_scope = stream.source_scope_revision
    configure(@connection, configuration) # Exact native CAS no-op.
    expect(stream.source_scope_revision).to eq(off_scope)
    configuration.fetch("native_capabilities")[
      "native_revision"
    ] = "descriptive-capability-revision:2"
    configure(@connection, configuration)
    expect(cursor.reload.invalidated_at).to be_nil
    expect(cursor.scope_signature).to eq(cursor_scope)
    expect(upload.reload.invalidated_at).to be_nil
    expect(upload.scope_signature).to eq(upload_scope)
    expect(upload.expires_at).to eq(expiry)
    expect(catalog.read("kind" => "authors", "cursor" => token).body.fetch("items")).to eq(
      [last_item],
    )
    catalog.append_page(
      upload.upload_id,
      {
        "mutation_id" => SecureRandom.uuid,
        "page" => 0,
        "items" => [
          { "id" => "new-native-author", "label" => "New native author", "available" => true },
        ],
      },
    )
    expect(upload.reload.received_items).to eq(1)
  end

  %w[profile destination_origin publication_lane].each do |field|
    it "durably invalidates real catalog cursor/upload on actual #{field} configure change and rejects ABA restoration" do
      connection, =
        DiscussionBridgeContentConnection.issue!(
          name: "Catalog configuration #{field} authority fixture",
          platform: field == "profile" ? "statamic" : "ghost",
          allowed_origins: %w[https://site.example https://other.example],
          allowed_directions: ["from_discourse"],
          allowed_lanes: %w[news other],
        )
      configuration = input_configuration
      configuration["profile"] = "statamic_db" if field == "profile"
      configure(connection, configuration)
      catalog, token, cursor, upload, = catalog_scope_fixture(connection)
      original = configuration.deep_dup
      replacement = {
        "profile" => "statamic_flat",
        "destination_origin" => "https://other.example",
        "publication_lane" => "other",
      }.fetch(field)
      configuration[field] = replacement
      configure(connection, configuration)
      expect(cursor.reload.invalidated_at).not_to be_nil
      expect(upload.reload.invalidated_at).not_to be_nil
      configure(connection, original)
      @now -= 1.day
      rejected("cursor_expired") { catalog.read("kind" => "authors", "cursor" => token) }
      rejected("catalog_upload_expired") do
        catalog.append_page(
          upload.upload_id,
          {
            "mutation_id" => SecureRandom.uuid,
            "page" => 0,
            "items" => [
              {
                "id" => "still-native-author",
                "label" => "Still native author",
                "available" => true,
              },
            ],
          },
        )
      end
      expect(cursor.catalog_snapshot.entries.count).to eq(101)
    end
  end

  it "makes a no-SourceStream metadata cursor remain invalid at identical scope after receiver invalidation and clock rollback" do
    other, = native_connection("No SourceStream authority fixture")
    configure(other, input_configuration)
    mapping = mapping_fixture(other, topic)
    token = history_cursor(other, mapping)
    cursor = DiscussionBridgeCmsReadCursor.find_by!(token_digest: Digest::SHA256.hexdigest(token))
    snapshot = cursor.cms_read_snapshot
    payload = cursor.page_body.deep_dup
    policy = other.reload.cms_configuration.deep_dup
    expect(DiscussionBridgeCmsSourceStream.where(content_connection_id: other.id)).to be_empty
    DiscussionBridge::CmsSourceLifecycle.invalidate_connection!(
      other,
      reason: "source_scope_changed",
      clock: -> { @now },
    )
    @now -= 1.day
    rejected("cursor_expired") do
      DiscussionBridge::CmsMappingReadStore.new(other, clock: -> { @now }).url_history(
        mapping.mapping_id,
        "cursor" => token,
      )
    end
    expect(snapshot.reload.invalidated_at).not_to be_nil
    expect(cursor.reload.page_body).to eq(payload)
    expect(other.reload.cms_configuration).to eq(policy)
    expect(DiscussionBridgeCmsSourceStream.where(content_connection_id: other.id)).to be_empty
  end

  it "retains terminal source counters but rejects old source and metadata cursors at identical scope after invalidation and clock rollback" do
    retained_stream = stream
    retained_stream.update!(source_scope_revision: DiscussionBridge::CmsProtocol::MAX_COUNTER)
    token = @store.feed("stream" => "initial").body.fetch("checkpoint_cursor")
    read_token = history_cursor(@connection, @mapping)
    source_cursor =
      DiscussionBridgeCmsSourceCursor.find_by!(token_digest: Digest::SHA256.hexdigest(token))
    DiscussionBridge::CmsSourceLifecycle.invalidate_connection!(
      @connection,
      reason: "source_scope_changed",
      clock: -> { @now },
    )
    @now -= 1.day
    rejected("cursor_expired") { @store.feed("stream" => "changes", "cursor" => token) }
    rejected("cursor_expired") do
      DiscussionBridge::CmsMappingReadStore.new(@connection, clock: -> { @now }).url_history(
        @mapping.mapping_id,
        "cursor" => read_token,
      )
    end
    expect(retained_stream.reload.source_scope_revision).to eq(
      DiscussionBridge::CmsProtocol::MAX_COUNTER,
    )
    expect(retained_stream.lifecycle_error_code).to eq("storage_exhausted")
    expect(source_cursor.reload.invalidated_at).not_to be_nil
    rejected("storage_exhausted") { @store.intent(@mapping.source_id, for_mutation: true) }
    expect(@work.reload.state).to eq("cancelled")
    expect(@mapping.reload.destination_native_id).to eq("fixture:native:authority:#{topic.id}")
  end

  it "preserves private append-only scope audit and rejects credential or invented actor facts" do
    @connection.update!(allowed_lanes: %w[news other])
    event = audit
    expect { event.update!(reason: "connection_disabled") }.to raise_error(
      ActiveRecord::RecordNotSaved,
    )
    expect { event.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    invalid = event.dup
    invalid.changed_fields = ["secret_digest"]
    invalid.previous_values = { "secret_digest" => @connection.secret_digest }
    invalid.values = { "secret_digest" => "a" * 64 }
    expect(invalid.valid?).to eq(false)
    invalid = event.dup
    invalid.actor_user_id = admin.id
    expect(invalid.valid?).to eq(false)
  end

  it "obeys frozen raw scope removal cancellation while retaining prior attention failure, cycle, count and native proof" do
    @work.update!(
      state: "attention",
      attempt: 3,
      last_failure_code: "public_verification_failed",
      lease_verifier: nil,
      lease_expires_at: nil,
    )
    @mapping.update!(
      mapping_state: "attention",
      prepared_transaction: {
        "fixture" => "retained preparation",
      },
      verified_result: {
        "fixture" => "historical public proof",
      },
    )
    retained =
      @work.reload.attributes.slice(
        "attempt",
        "attempt_cycle",
        "last_failure_code",
        "failure_detail",
        "source_revision",
        "policy_revision",
        "lease_generation",
      )
    @connection.update!(allowed_origins: ["https://other.example"])
    expect(@work.reload.state).to eq("cancelled")
    expect(@work.attributes.slice(*retained.keys)).to eq(retained)
    expect(@mapping.reload.prepared_transaction).to eq("fixture" => "retained preparation")
    expect(@mapping.verified_result).to eq("fixture" => "historical public proof")
    expect(@queued).to be_empty
  end
end
