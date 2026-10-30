# frozen_string_literal: true

require "rails_helper"

# Native Rails/PostgreSQL request and persistence regressions. Reports below are
# synthetic native-owner facts; no CMS write/public HTTP qualification is claimed.
RSpec.describe DiscussionBridge::CmsAdminAttentionController, type: :request do
  fab!(:admin)
  fab!(:moderator)
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) do
    Fabricate(
      :post,
      topic: topic,
      user: admin,
      post_number: 1,
      raw: "Native attention source.",
      cooked: "<p>Native attention source.</p>"
    )
  end

  before do
    # Isolate asynchronous discovery scheduling only. Actual SQL source capture,
    # configuration/authority, controllers and coordinator remain unchanged.
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(
      :wake_connection
    ).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    SiteSetting.login_required = false
    https!
    admin.reload
    @native_headers = { "X-Requested-With" => "XMLHttpRequest" }
    @connection, @secret = issue_connection
    @mapping =
      publication(@connection, topic: topic, external_id: "attention-article")
    @work = @mapping.work_items.order(:id).last
    @wire_headers = wire_headers(@connection, @secret)
  end

  def issue_connection(
    profile: "ghost",
    kind: "dynamic",
    name: "Native attention fixture"
  )
    connection, secret =
      DiscussionBridgeContentConnection.issue!(
        name: name,
        platform: profile,
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"]
      )
    connection.update!(
      cms_configuration: {
        "profile" => profile,
        "destination_origin" => "https://site.example",
        "publication_lane" => "news",
        "native_capabilities" => {
          "native_revision" => "native:attention-fixture",
          "supported_presentations" => %w[simple full],
          "publication_kind" => kind,
          "complete_content_supported" => true
        },
        "policy" => {
          "policy_revision" => SecureRandom.uuid,
          "enabled" => true,
          "selection" => "all_public",
          "category_ids" => [],
          "include_topic_ids" => [],
          "exclude_topic_ids" => [],
          "include_unlisted" => false,
          "publication_kind" => kind,
          "presentation_mode" => "simple",
          "author_ids" => [],
          "taxonomy_ids" => []
        }
      }
    )
    [connection, secret]
  end

  def publication(connection, topic:, external_id:)
    result =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: connection.id,
        topic_id: topic.id,
        external_id: external_id,
        canonical_url: "https://site.example/#{external_id}/"
      )
    DiscussionBridgeCmsMapping.find_by!(
      content_binding_id: result.record.active_binding("presentation").id
    )
  end

  def wire_headers(connection, secret)
    @native_headers.merge(
      "X-DiscussionBridge-Connection" => connection.public_id,
      "X-DiscussionBridge-Secret" => secret
    )
  end

  def authority(lease)
    work = lease.fetch("work")
    {
      "work_id" => work.fetch("work_id"),
      "lease_token" => lease.fetch("lease_token"),
      "lease_generation" => lease.fetch("lease_generation"),
      "source_revision" => work.fetch("source_revision"),
      "policy_revision" => work.fetch("policy_revision")
    }
  end

  def attention!(mapping = @mapping, code: "native_ownership_conflict")
    coordinator =
      DiscussionBridge::CmsWorkCoordinator.new(mapping.content_connection)
    lease =
      coordinator.claim(
        {
          "mutation_id" => SecureRandom.uuid,
          "mapping_id" => mapping.mapping_id
        }
      ).body
    expect(lease).to be_present
    coordinator.fail(
      lease.fetch("work").fetch("work_id"),
      {
        "mutation_id" => SecureRandom.uuid,
        "authority" => authority(lease),
        "code" => code,
        "native_change_applied" => false,
        "safe_detail" => nil,
        "retry_after_seconds" => nil
      }
    )
    mapping.work_items.order(:id).last.reload
  end

  def check_input(work = @work)
    {
      "mutation_id" => SecureRandom.uuid,
      "selected" => [
        {
          "work_id" => work.work_id,
          "mapping_revision" => work.cms_mapping.mapping_revision
        }
      ]
    }
  end

  def native_action(action, input, connection: @connection)
    post "/admin/content-connections/#{connection.id}/cms-attention/#{action}.json",
         params: input,
         headers: @native_headers,
         as: :json
  end

  def native_check(work = @work, input: nil, connection: @connection)
    native_action("check", input || check_input(work), connection: connection)
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    row = body.fetch("items").first
    expect(row.fetch("status")).to eq("waiting")
    DiscussionBridgeCmsAttentionInspection.find_by!(
      inspection_id: row.fetch("inspection_id")
    )
  end

  def absent_initial_observation(profile: "ghost-dynamic-1")
    {
      "profile" => profile,
      "observed_at" => Time.current.utc.iso8601(3),
      "native_state" => "never_applied",
      "object_exists" => false,
      "native_id" => nil,
      "native_revision" => nil,
      "ownership" => nil,
      "native_result" => nil,
      "verification" => nil,
      "source_revision" => nil,
      "managed_content_sha256" => nil,
      "native_command" => "none",
      "pending_mutation" => "none",
      "prepared_transaction_id" => nil,
      "journal_sha256" => "a" * 64,
      "baseline_sha256" => nil,
      "candidate_sha256" => nil,
      "current_sha256" => nil,
      "restoration_operation_id" => nil,
      "issue" => "none"
    }
  end

  def report_input(inspection, observation = absent_initial_observation)
    {
      "mutation_id" => SecureRandom.uuid,
      "context_sha256" => inspection.context_sha256,
      "observation" => observation
    }
  end

  def report(inspection, input, headers: @wire_headers)
    post "/discussion-bridge/v4/attention-inspections/#{inspection.inspection_id}/report.json",
         params: input,
         headers: headers,
         as: :json
  end

  def ready_inspection(work = @work, connection: @connection, secret: @secret)
    inspection = native_check(work, connection: connection)
    report(
      inspection,
      report_input(inspection),
      headers: wire_headers(connection, secret)
    )
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("status")).to eq("ready")
    inspection.reload
  end

  def retry_input(*inspections, settle: false)
    {
      "mutation_id" => SecureRandom.uuid,
      "selected" =>
        inspections.map do |inspection|
          {
            "inspection_id" => inspection.inspection_id,
            "context_sha256" => inspection.context_sha256,
            "settle_restored_baseline" => settle
          }
        end
    }
  end

  def native_counts
    [
      DiscussionBridgeCmsWork,
      DiscussionBridgeCmsAttentionInspection,
      DiscussionBridgeCmsAttentionRecovery,
      DiscussionBridgeCmsMutationReceipt
    ].to_h { |model| [model.table_name, model.count] }
  end

  def second_publication
    another_topic = Fabricate(:topic, user: admin)
    Fabricate(
      :post,
      topic: another_topic,
      user: admin,
      post_number: 1,
      raw: "Second native attention source.",
      cooked: "<p>Second native attention source.</p>"
    )
    publication(
      @connection,
      topic: another_topic,
      external_id: "second-attention"
    )
  end

  def native_result(mapping, digest:, revision:, receipt:)
    {
      "kind" => "publish_revision",
      "native_id" => "fixture:#{mapping.id}",
      "external_id" => mapping.content_binding.external_id,
      "canonical_url" => mapping.content_binding.canonical_url,
      "native_revision" => revision,
      "ownership_receipt_sha256" => receipt,
      "representation" => {
        "kind" => "full",
        "source_content_sha256" => digest
      }
    }
  end

  def synthetic_public_proof(mapping, result, source_revision)
    # Typed retained/current public facts only; no actual external verifier runs.
    {
      "kind" => "published",
      "url" => mapping.content_binding.canonical_url,
      "native_id" => result.fetch("native_id"),
      "source_revision" => source_revision,
      "source_content_sha256" =>
        result.fetch("representation").fetch("source_content_sha256"),
      "native_publication_sha256" => "e" * 64,
      "verification_profile" => "synthetic:no-http",
      "checked_at" => Time.current.utc.iso8601(3),
      "representation" => result.fetch("representation")
    }
  end

  it "loads the additive native schema with real defaults, unique lineage and foreign keys" do
    adapter = ActiveRecord::Base.connection
    %w[inspections recoveries notices deliveries].each do |suffix|
      expect(
        adapter.table_exists?("discussion_bridge_cms_attention_#{suffix}")
      ).to eq(true)
    end
    index =
      adapter
        .indexes("discussion_bridge_cms_work")
        .find { |item| item.name == "idx_db_cms_work_retry_predecessor" }
    expect(index).to be_present
    expect(index.unique).to eq(true)
    expect(index.columns).to eq(["retry_of_work_id"])
    expect(DiscussionBridgeCmsWork.new).to have_attributes(
      attempt: 0,
      lease_generation: 0,
      state: "pending"
    )
    expect(
      adapter.foreign_keys("discussion_bridge_cms_attention_recoveries").map(
        &:column
      )
    ).to include(
      "predecessor_work_id",
      "successor_work_id",
      "inspection_record_id"
    )
  end

  it "does not let valid connector credentials substitute for a native administrator session" do
    @work = attention!
    before = native_counts
    post "/admin/content-connections/#{@connection.id}/cms-attention/check.json",
         params: check_input,
         headers: @wire_headers,
         as: :json
    expect(response).to have_http_status(:forbidden)
    expect(native_counts).to eq(before)
  end

  it "denies nonadministrators and reloads a previously signed-in administrator whose role was revoked" do
    @work = attention!
    before = native_counts
    [user, moderator].each do |actor|
      sign_in(actor)
      native_action("check", check_input)
      expect(response).to have_http_status(:forbidden)
      expect(native_counts).to eq(before)
    end
    sign_in(admin)
    native_check
    before = native_counts
    User.where(id: admin.id).update_all(admin: false)
    native_action("check", check_input)
    expect(response).to have_http_status(:forbidden)
    expect(native_counts).to eq(before)
    expect do
      DiscussionBridge::CmsAttentionRecovery.new(@connection).check(
        actor: admin,
        input: check_input
      )
    end.to raise_error(Discourse::InvalidAccess)
    expect(native_counts).to eq(before)
  end

  it "keeps native CSRF protection distinct from a valid signed-in administrator session" do
    @work = attention!
    sign_in(admin)
    native_check
    before = native_counts
    original = ApplicationController.allow_forgery_protection
    begin
      ApplicationController.allow_forgery_protection = true
      expect(described_class.allow_forgery_protection).to eq(true)
      native_action("check", check_input)
      expect(response).to have_http_status(:forbidden)
      expect(native_counts).to eq(before)
    ensure
      ApplicationController.allow_forgery_protection = original
    end
  end

  it "rejects unknown, duplicate and query-bearing native JSON before changing SQL state" do
    @work = attention!
    sign_in(admin)
    before = native_counts
    [
      ["", JSON.generate(check_input.merge("ready" => true)), "unknown_field"],
      ["", '{"mutation_id":"a","mutation_id":"b"}', "invalid_json"],
      ["?ready=true", JSON.generate(check_input), "invalid_field"]
    ].each do |query, raw, code|
      post "/admin/content-connections/#{@connection.id}/cms-attention/check.json#{query}",
           params: raw,
           headers: @native_headers.merge("Content-Type" => "application/json")
      failure_context =
        "case=#{code.inspect} query=#{query.inspect} status=#{response.status} body=#{response.body.to_s.byteslice(0, 2048).inspect}"
      expect(response.status).to eq(
        DiscussionBridge::CmsProtocol::ERRORS.fetch(code).fetch("http")
      ),
      failure_context
      expect(response.parsed_body.fetch("code")).to eq(code)
      expect(native_counts).to eq(before)
    end
  end

  it "persists one encrypted Check context and replays the exact native action UUID" do
    @work = attention!
    sign_in(admin)
    input = check_input
    work_before = @work.attributes.deep_dup
    inspection = native_check(input: input)
    first = response.parsed_body
    expect(inspection.payload_tree.keys).to eq(["ciphertext"])
    payload =
      DiscussionBridge::CmsReceiptCipher.decrypt(inspection.payload_tree)
    DiscussionBridge::CmsProtocol.validate!("AttentionInspection", payload)
    expect(payload.fetch("work").fetch("work_id")).to eq(@work.work_id)
    expect(payload.fetch("mapping").fetch("mapping_id")).to eq(
      @mapping.mapping_id
    )
    native_action("check", input)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(first)
    expect(
      DiscussionBridgeCmsAttentionInspection.where(cms_work_id: @work.id).count
    ).to eq(1)
    expect(@work.reload.attributes).to eq(work_before)
    receipt =
      DiscussionBridgeCmsMutationReceipt.find_by!(
        route: "attention_admin_check",
        mutation_id: input.fetch("mutation_id")
      )
    expect(receipt.native_actor_user_id).to eq(admin.id)
    expect(receipt.request_tree.keys).to eq(["ciphertext"])
  end

  it "requires current connector headers for report and never creates work from a ready report or replay" do
    @work = attention!
    sign_in(admin)
    inspection = native_check
    input = report_input(inspection)
    work_before = @work.attributes.deep_dup
    report(inspection, input, headers: @native_headers)
    expect(response.parsed_body.fetch("code")).to eq("authentication_required")
    expect(inspection.reload.observation_tree).to be_nil
    report(
      inspection,
      input,
      headers: @wire_headers.merge("X-DiscussionBridge-Secret" => "wrong")
    )
    expect(response.parsed_body.fetch("code")).to eq("authentication_failed")
    report(inspection, input)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("status")).to eq("ready")
    accepted = response.parsed_body
    tree = inspection.reload.observation_tree.deep_dup
    report(inspection, input)
    expect(response.parsed_body).to eq(accepted)
    expect(inspection.reload.observation_tree).to eq(tree)
    expect(@mapping.work_items.count).to eq(1)
    expect(@work.reload.attributes).to eq(work_before)
  end

  it "appends one fresh explicit cycle, protects old history and enforces predecessor uniqueness in PostgreSQL" do
    @work = attention!
    sign_in(admin)
    inspection = ready_inspection
    before_ids = [
      topic.id,
      first_post.id,
      @mapping.content_binding.bridge_record.resource_id,
      @mapping.mapping_id
    ]
    input = retry_input(inspection)
    native_action("retry", input)
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.fetch("items").first.fetch("status")).to eq("queued")
    recovery =
      DiscussionBridgeCmsAttentionRecovery.find_by!(
        predecessor_work_id: @work.id
      )
    successor = recovery.successor_work
    expect(@work.reload.state).to eq("superseded")
    expect(successor).to have_attributes(
      state: "pending",
      attempt: 0,
      retry_of_work_id: @work.id,
      lease_generation: @mapping.reload.fence_generation
    )
    expect(successor.work_id).not_to eq(@work.work_id)
    expect(successor.attempt_cycle).not_to eq(@work.attempt_cycle)
    expect(successor.source_snapshot).to eq(@work.source_snapshot)
    snapshot =
      DiscussionBridge::CmsReceiptCipher.decrypt(recovery.attention_snapshot)
    expect(snapshot.fetch("work").fetch("state")).to eq("attention")
    expect(snapshot.fetch("work")).not_to have_key("lease_verifier")
    expect(
      [
        topic.id,
        first_post.id,
        @mapping.content_binding.bridge_record.resource_id,
        @mapping.mapping_id
      ]
    ).to eq(before_ids)
    native_action("retry", input)
    expect(response.parsed_body).to eq(body)
    native_action("retry", input.merge("mutation_id" => SecureRandom.uuid))
    expect(
      response.parsed_body.fetch("items").first.fetch("successor_work_id")
    ).to eq(successor.work_id)
    expect(@mapping.work_items.count).to eq(2)
    expect do
      DiscussionBridgeCmsWork.transaction(requires_new: true) do
        duplicate = successor.dup
        duplicate.work_id = SecureRandom.uuid
        duplicate.attempt_cycle = SecureRandom.uuid
        duplicate.save!
      end
    end.to raise_error(ActiveRecord::RecordNotUnique) { |error|
      expect(error.message).to include("idx_db_cms_work_retry_predecessor")
    }
    expect {
      recovery.update!(mode: "settle_restored_baseline")
    }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "keeps restored metadata manual and refuses retry after the captured source context changes" do
    @work = attention!(code: "metadata_unavailable")
    sign_in(admin)
    before = @work.attributes.deep_dup
    delivery = DiscussionBridge::CmsDeliveryProjection.call(@mapping.reload)
    expect(
      delivery.fetch("attention_recovery").fetch("metadata_restored")
    ).to eq(true)
    expect(@work.reload.attributes).to eq(before)
    expect(@mapping.work_items.count).to eq(1)
    inspection = ready_inspection
    first_post.update_columns(version: first_post.version + 1)
    native_action("retry", retry_input(inspection))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("items").first).to include(
      "status" => "stale",
      "issue" => "context_changed"
    )
    expect(@work.reload.state).to eq("attention")
    expect(@mapping.work_items.count).to eq(1)
  end

  it "rolls back a late selected-item failure without rolling back another selected retry" do
    @work = attention!
    other_mapping = second_publication
    other_work = attention!(other_mapping)
    sign_in(admin)
    first = ready_inspection
    second = ready_inspection(other_work)
    # Deliberate fault after real SQL insertion, before its per-item savepoint
    # completes. No alternative persistence/coordinator implementation is used.
    allow(DiscussionBridgeCmsAttentionRecovery).to receive(
      :create!
    ).and_wrap_original do |original, *arguments, **keywords|
      attributes = keywords.empty? ? arguments.fetch(0) : keywords
      row = original.call(*arguments, **keywords)
      if attributes.fetch(:cms_mapping_id) == other_mapping.id
        DiscussionBridge::CmsProtocol.reject!("revision_conflict")
      end
      row
    end
    native_action("retry", retry_input(first, second))
    expect(response).to have_http_status(:ok)
    expect(
      response.parsed_body.fetch("items").map { |item| item.fetch("status") }
    ).to eq(%w[queued stale])
    expect(@work.reload.state).to eq("superseded")
    expect(@mapping.work_items.count).to eq(2)
    expect(other_work.reload.state).to eq("attention")
    expect(other_mapping.reload.mapping_state).to eq("attention")
    expect(other_mapping.work_items.count).to eq(1)
    expect(
      DiscussionBridgeCmsAttentionRecovery.where(
        cms_mapping_id: other_mapping.id
      )
    ).to be_empty
  end

  it "requires the exact positive recovery claim and advances the durable mapping fence once" do
    @work = attention!
    sign_in(admin)
    inspection = ready_inspection
    old_generation = @mapping.reload.fence_generation
    native_action("retry", retry_input(inspection))
    recovery =
      DiscussionBridgeCmsAttentionRecovery.find_by!(
        predecessor_work_id: @work.id
      )
    post "/discussion-bridge/v4/work/claim.json",
         params: {
           "mutation_id" => SecureRandom.uuid
         },
         headers: @wire_headers,
         as: :json
    expect(response).to have_http_status(:no_content)
    successor = recovery.successor_work
    expect(successor.reload.state).to eq("pending")
    input = {
      "mutation_id" => SecureRandom.uuid,
      "work_id" => successor.work_id
    }
    path =
      "/discussion-bridge/v4/work/recoveries/#{recovery.recovery_id}/claim.json"
    post path, params: input, headers: @wire_headers, as: :json
    expect(response).to have_http_status(:ok)
    lease = response.parsed_body
    expect(lease.fetch("work").fetch("work_id")).to eq(successor.work_id)
    expect(lease.fetch("lease_generation")).to eq(old_generation + 1)
    expect(@mapping.reload.fence_generation).to eq(old_generation + 1)
    post path, params: input, headers: @wire_headers, as: :json
    expect(response.parsed_body).to eq(lease)
    expect(@mapping.reload.fence_generation).to eq(old_generation + 1)
  end

  it "uses increasing bounded SQL inspection feeds with scoped continuation and no foreign-connection rows" do
    @work = attention!
    store = DiscussionBridge::CmsAttentionRecovery.new(@connection)
    ids =
      27.times.map do
        item =
          store
            .check(actor: admin, input: check_input)
            .body
            .fetch("items")
            .first
        DiscussionBridgeCmsAttentionInspection.find_by!(
          inspection_id: item.fetch("inspection_id")
        ).id
      end
    foreign_connection, =
      issue_connection(name: "Native attention foreign feed fixture")
    foreign_topic = Fabricate(:topic, user: admin)
    Fabricate(
      :post,
      topic: foreign_topic,
      user: admin,
      post_number: 1,
      raw: "Foreign-connection native source.",
      cooked: "<p>Foreign-connection native source.</p>"
    )
    foreign_mapping =
      publication(
        foreign_connection,
        topic: foreign_topic,
        external_id: "foreign-attention"
      )
    foreign_work = attention!(foreign_mapping)
    foreign =
      DiscussionBridge::CmsAttentionRecovery.new(foreign_connection).check(
        actor: admin,
        input: check_input(foreign_work)
      )
    foreign_id = foreign.body.fetch("items").first.fetch("inspection_id")
    get "/discussion-bridge/v4/attention-inspections.json",
        params: {
          after: 0
        },
        headers: @wire_headers
    expect(response).to have_http_status(:ok)
    first = response.parsed_body
    expect(first.fetch("items").map { |item| item.fetch("sequence") }).to eq(
      ids.first(25)
    )
    expect(first.fetch("has_more")).to eq(true)
    get "/discussion-bridge/v4/attention-inspections.json",
        params: {
          after: first.fetch("next_after")
        },
        headers: @wire_headers
    second = response.parsed_body
    expect(second.fetch("items").map { |item| item.fetch("sequence") }).to eq(
      ids.last(2)
    )
    expect(second.fetch("has_more")).to eq(false)
    expect(
      (first.fetch("items") + second.fetch("items")).map do |item|
        item.fetch("inspection_id")
      end
    ).not_to include(foreign_id)
    get "/discussion-bridge/v4/attention-inspections.json",
        params: {
          after: second.fetch("next_after")
        },
        headers: @wire_headers
    expect(response.parsed_body).to eq(
      "items" => [],
      "next_after" => ids.last,
      "has_more" => false
    )
    expect(@work.reload.state).to eq("attention")
  end

  it "returns authorized international-domain attention rows without leaking a previous origin" do
    old_work = attention!
    sign_in(admin)
    native_check(old_work)
    @connection.update!(
      allowed_origins: %w[https://site.example https://xn--9ca.example]
    )
    config = @connection.cms_configuration.deep_dup
    config["destination_origin"] = "https://é.example"
    @connection.update!(cms_configuration: config)
    international_topic = Fabricate(:topic, user: admin)
    Fabricate(:post, topic: international_topic, user: admin, post_number: 1)
    result =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: international_topic.id,
        external_id: "international-attention",
        canonical_url: "https://%C3%A9.example/article/"
      )
    mapping =
      DiscussionBridgeCmsMapping.find_by!(
        content_binding_id: result.record.active_binding("presentation").id
      )
    work = attention!(mapping)
    sign_in(admin)
    inspection = native_check(work)
    get "/discussion-bridge/v4/attention-inspections.json",
        params: {
          after: 0
        },
        headers: @wire_headers
    expect(response).to have_http_status(:ok)
    expect(
      response
        .parsed_body
        .fetch("items")
        .map { |item| item.fetch("inspection_id") }
    ).to eq([inspection.inspection_id])
    expect(response.parsed_body.fetch("has_more")).to eq(false)
    expect(mapping.reload.content_binding.canonical_url).to eq(
      "https://%C3%A9.example/article/"
    )
    get "/discussion-bridge/v4/attention-recovery.json", headers: @wire_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("candidate_id")).to eq(
      "discussionbridge-v4-core-20261025-r6"
    )
  end

  it "settles only the explicitly named exact static preparation and retains its complete previous snapshot" do
    connection, secret =
      issue_connection(
        profile: "astro",
        kind: "static",
        name: "Native attention static fixture"
      )
    mapping =
      publication(connection, topic: topic, external_id: "static-attention")
    work = mapping.work_items.order(:id).last
    baseline_revision = "baseline:0"
    baseline =
      native_result(
        mapping,
        digest: Digest::SHA256.hexdigest("earlier source"),
        revision: "native:baseline",
        receipt: "b" * 64
      )
    prior_proof = synthetic_public_proof(mapping, baseline, baseline_revision)
    mapping.update!(
      destination_native_id: baseline.fetch("native_id"),
      destination_native_revision: baseline.fetch("native_revision"),
      synchronized_source_revision: baseline_revision,
      publicly_verified_source_revision: baseline_revision,
      native_result: baseline,
      verified_result: {
        "native_result" => baseline,
        "verification" => prior_proof
      },
      synchronized_at: 2.minutes.ago,
      publicly_verified_at: 1.minute.ago
    )
    coordinator = DiscussionBridge::CmsWorkCoordinator.new(connection)
    lease =
      coordinator.claim(
        {
          "mutation_id" => SecureRandom.uuid,
          "mapping_id" => mapping.mapping_id
        }
      ).body
    candidate =
      native_result(
        mapping,
        digest: work.source_snapshot.fetch("content_sha256"),
        revision: "native:candidate",
        receipt: "c" * 64
      )
    transaction_id = SecureRandom.uuid
    coordinator.prepare(
      work.work_id,
      {
        "mutation_id" => SecureRandom.uuid,
        "authority" => authority(lease),
        "transaction_id" => transaction_id,
        "native_result" => candidate,
        "prepared_at" => Time.current.utc.iso8601(3)
      }
    )
    coordinator.fail(
      work.work_id,
      {
        "mutation_id" => SecureRandom.uuid,
        "authority" => authority(lease),
        "code" => "native_restore_required",
        "native_change_applied" => true,
        "safe_detail" => nil,
        "retry_after_seconds" => nil
      }
    )
    work.reload
    preparation = mapping.reload.prepared_transaction.deep_dup
    sign_in(admin)
    inspection = native_check(work, connection: connection)
    observation =
      absent_initial_observation(profile: "astro-static-1").merge(
        "native_state" => "restored_baseline",
        "object_exists" => true,
        "native_id" => baseline.fetch("native_id"),
        "native_revision" => baseline.fetch("native_revision"),
        "native_result" => baseline,
        "ownership" => {
          "resource_id" => mapping.content_binding.bridge_record.resource_id,
          "external_id" => mapping.content_binding.external_id,
          "native_id" => baseline.fetch("native_id"),
          "canonical_url" => mapping.content_binding.canonical_url,
          "source_revision" => baseline_revision,
          "ownership_receipt_sha256" =>
            baseline.fetch("ownership_receipt_sha256")
        },
        "verification" =>
          synthetic_public_proof(mapping, baseline, baseline_revision),
        "source_revision" => baseline_revision,
        "managed_content_sha256" => "d" * 64,
        "prepared_transaction_id" => transaction_id,
        "baseline_sha256" => "f" * 64,
        "current_sha256" => "f" * 64
      )
    report(
      inspection,
      report_input(inspection, observation),
      headers: wire_headers(connection, secret)
    )
    expect(response.parsed_body.fetch("status")).to eq("ready")
    native_action("retry", retry_input(inspection), connection: connection)
    expect(response.parsed_body.fetch("items").first.fetch("status")).to eq(
      "conflict"
    )
    expect(mapping.reload.prepared_transaction).to eq(preparation)
    native_action(
      "retry",
      retry_input(inspection, settle: true),
      connection: connection
    )
    expect(response.parsed_body.fetch("items").first.fetch("status")).to eq(
      "queued"
    )
    expect(mapping.reload.prepared_transaction).to be_nil
    expect(mapping.native_result).to eq(baseline)
    expect(mapping.synchronized_source_revision).to eq(baseline_revision)
    recovery =
      DiscussionBridgeCmsAttentionRecovery.find_by!(
        predecessor_work_id: work.id
      )
    expect(recovery.mode).to eq("settle_restored_baseline")
    expect(
      DiscussionBridge::CmsReceiptCipher
        .decrypt(recovery.attention_snapshot)
        .fetch("mapping")
        .fetch("prepared_transaction")
    ).to eq(preparation)
    expect(work.reload.state).to eq("superseded")
    expect(recovery.successor_work.source_snapshot).to eq(work.source_snapshot)
  end

  it "leaves a different prior Work preparation Not ready without persisting an invalid inspection" do
    @work = attention!
    old_work =
      @mapping.work_items.create!(
        work_id: SecureRandom.uuid,
        attempt_cycle: SecureRandom.uuid,
        action: "publish_revision",
        state: "superseded",
        source_revision: "older:source",
        policy_revision: "older:policy",
        source_snapshot:
          @work.source_snapshot.merge("source_revision" => "older:source"),
        lease_generation: 1,
        created_at: @work.created_at - 1.minute
      )
    candidate =
      native_result(
        @mapping,
        digest: @work.source_snapshot.fetch("content_sha256"),
        revision: "native:older",
        receipt: "c" * 64
      )
    preparation = {
      "transaction_id" => SecureRandom.uuid,
      "work_id" => old_work.work_id,
      "lease_generation" => 1,
      "action" => "publish_revision",
      "source_revision" => old_work.source_revision,
      "policy_revision" => old_work.policy_revision,
      "native_result" => candidate,
      "prepared_at" => Time.current.utc.iso8601(3)
    }
    @mapping.update!(prepared_transaction: preparation)
    sign_in(admin)
    before = native_counts
    native_action("check", check_input)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("items").first).to include(
      "status" => "not_ready",
      "issue" => "context_changed",
      "inspection_id" => nil
    )
    expect(DiscussionBridgeCmsAttentionInspection.count).to eq(
      before.fetch(DiscussionBridgeCmsAttentionInspection.table_name)
    )
    expect(DiscussionBridgeCmsAttentionRecovery.count).to eq(0)
    expect(@mapping.reload.prepared_transaction).to eq(preparation)
    expect(@work.reload.state).to eq("attention")
  end

  it "deduplicates actual attention recipients and rechecks native eligibility before delivery" do
    eligible = Fabricate(:admin)
    inactive, staged, suspended = 3.times.map { Fabricate(:admin) }
    # Intentional persisted native-state fixtures; the recipient guard must read
    # actual database flags rather than trusting a previously loaded object.
    inactive.update_columns(active: false)
    staged.update_columns(staged: true)
    suspended.update_columns(suspended_till: 1.day.from_now)
    @work = attention!
    notice = DiscussionBridgeCmsAttentionNotice.find_by!(cms_work_id: @work.id)
    recipient_ids =
      DiscussionBridgeCmsAttentionDelivery.where(notice_id: notice.id).pluck(
        :user_id
      )
    expect(recipient_ids).to include(admin.id, eligible.id)
    expect(
      recipient_ids &
        [user.id, moderator.id, inactive.id, staged.id, suspended.id]
    ).to be_empty
    count =
      DiscussionBridgeCmsAttentionDelivery.where(notice_id: notice.id).count
    DiscussionBridge::CmsAttentionNotifications.record!(@work)
    expect(
      DiscussionBridgeCmsAttentionNotice.where(cms_work_id: @work.id).count
    ).to eq(1)
    expect(
      DiscussionBridgeCmsAttentionDelivery.where(notice_id: notice.id).count
    ).to eq(count)
    eligible.update_columns(admin: false)
    allow(NotificationEmailer).to receive(
      :process_notification
    ).and_call_original
    DiscussionBridge::CmsAttentionNotifications.dispatch
    expect(NotificationEmailer).not_to have_received(:process_notification)
    revoked =
      DiscussionBridgeCmsAttentionDelivery.find_by!(
        notice_id: notice.id,
        user_id: eligible.id
      )
    expect(revoked.skipped_at).to be_present
    expect(revoked.notification_id).to be_nil
    expect(
      DiscussionBridgeCmsAttentionDelivery.find_by!(
        notice_id: notice.id,
        user_id: admin.id
      ).delivered_at
    ).to be_present
  end

  it "executes Core creation callbacks with email suppressed and preserves ordinary read state and bell replay" do
    @work = attention!
    notice = DiscussionBridgeCmsAttentionNotice.find_by!(cms_work_id: @work.id)
    callback_flags = []
    # Observe, then call the actual Core callback. A zero-callback run fails;
    # merely not receiving an email call cannot establish this assertion.
    allow_any_instance_of(Notification).to receive(
      :send_email
    ).and_wrap_original do |original, *arguments|
      notification = original.receiver
      if notification.data_hash["message"] ==
           DiscussionBridge::CmsAttentionNotifications::MESSAGE
        callback_flags << notification.skip_send_email
      end
      original.call(*arguments)
    end
    allow(NotificationEmailer).to receive(
      :process_notification
    ).and_call_original
    DiscussionBridge::CmsAttentionNotifications.dispatch
    expect(NotificationEmailer).not_to have_received(:process_notification)
    delivery =
      DiscussionBridgeCmsAttentionDelivery.find_by!(
        notice_id: notice.id,
        user_id: admin.id
      )
    notification = Notification.find(delivery.notification_id)
    expect(callback_flags).not_to be_empty
    expect(callback_flags).to all(eq(true))
    expect(notification.notification_type).to eq(
      Notification.types.fetch(:custom)
    )
    expect(notification.data_hash).to eq(
      "message" => "discussion_bridge.attention_notice",
      "title" => "discussion_bridge.attention_notice"
    )
    expect(notification.read).to eq(false)
    notification.update!(read: true)
    before_count = Notification.where(user_id: admin.id).count
    DiscussionBridge::CmsAttentionNotifications.dispatch
    expect(Notification.where(user_id: admin.id).count).to eq(before_count)
    expect(notification.reload.read).to eq(true)
  end
end
