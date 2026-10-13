# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsSourceLifecycle do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    # Dedicated event/job integration owns automatic dispatch. These fixtures
    # deliberately drive receiver operations and inspect each committed batch.
    allow(described_class).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @now = Time.current
    @queued = []
    @connection, =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS source lifecycle author fixture",
        platform: "hugo",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @configuration = {
      "profile" => "hugo",
      "destination_origin" => "https://site.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "native:1",
        "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic",
        "complete_content_supported" => true,
      },
      "policy" => {
        "policy_revision" => SecureRandom.uuid,
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
    @connection.update!(cms_configuration: @configuration)
    @lifecycle =
      described_class.new(@connection, clock: -> { @now }, enqueuer: ->(args) { @queued << args })
    @store = DiscussionBridge::CmsSourceStore.new(@connection, clock: -> { @now })
  end

  def stream
    DiscussionBridgeCmsSourceStream.find_by!(
      content_connection_id: @connection.id,
      publication_lane: "news",
    )
  end

  def create_mapping(native_id: nil)
    record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: topic.id,
        external_id: "article",
        canonical_url: "https://site.example/article/",
        lane: "news",
        native_materialization: true,
        presentation_mode: "simple",
      ).record
    DiscussionBridgeCmsMapping.create!(
      mapping_id: SecureRandom.uuid,
      content_connection: @connection,
      content_binding: record.active_binding("presentation"),
      source_id: "topic:#{topic.id}",
      mapping_revision: SecureRandom.uuid,
      destination_native_id: native_id,
    )
  end

  def change_policy(fields)
    configuration = @connection.cms_configuration.deep_dup
    configuration.fetch("policy").merge!(fields)
    @connection.update!(cms_configuration: configuration)
  end

  it "queues and admits no source lifecycle for off or disabled scopes" do
    change_policy("enabled" => false)
    expect(@lifecycle.run_batch.state).to eq("inactive")
    expect(@lifecycle.wake).to eq(false)
    expect(
      described_class.maintenance(clock: -> { @now }, enqueuer: ->(args) { @queued << args }),
    ).to eq(0)
    expect(@queued).to be_empty
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    change_policy("enabled" => true)
    @connection.update!(enabled: false)
    expect(@lifecycle.refresh(topic.id).error_code).to eq("connection_disabled")
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
  end

  it "commits at most one hundred native IDs and resumes persisted scan progress" do
    205.times { Fabricate(:topic, user: admin) }
    ids = Topic.unscoped.order(:id).pluck(:id)
    first = @lifecycle.run_batch
    expect(first.processed_count).to eq(100)
    expect(first.continuation).to eq(true)
    expect(stream.scan_last_topic_id).to eq(ids[99])
    expect(@queued.last).to eq(connection_id: @connection.id.to_s)
    resumed =
      described_class.new(
        @connection.reload,
        clock: -> { @now },
        enqueuer: ->(args) { @queued << args },
      )
    second = resumed.run_batch
    expect(second.processed_count).to eq(100)
    expect(stream.scan_last_topic_id).to eq(ids[199])
    batches = [first, second]
    loop do
      value = resumed.run_batch
      batches << value
      break if value.state == "complete"
    end
    expect(batches.map(&:processed_count).sum).to eq(ids.size)
    expect(batches.all? { |value| value.processed_count <= 100 }).to eq(true)
    expect(stream.scan_state).to eq("complete")
    expect(@store.feed("stream" => "initial").body.fetch("items").size).to eq(1)
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(1)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "retires retained hard-deleted source identities in bounded resumable batches" do
    @lifecycle.refresh(topic.id)
    retained = stream
    205.times do |index|
      retained.source_intents.create!(
        topic_id: 9_000_000_000 + index,
        source_id: "topic:#{9_000_000_000 + index}",
        state: "active",
        current_source_revision: "gone:#{index}",
      )
    end
    retained.update!(
      scan_state: "scanning",
      scan_phase: "retirement",
      scan_scope_signature: @store.scope_fingerprint(@connection.cms_configuration),
      scan_high_intent_id: retained.source_intents.maximum(:id),
      scan_last_intent_id: 0,
    )
    counts = []
    loop do
      value = @lifecycle.run_batch
      counts << value.processed_count
      break if value.state == "complete"
    end
    expect(counts).to eq([100, 100, 5, 0])
    expect(retained.source_intents.where(state: "revoked").count).to eq(205)
    expect(retained.source_events.where("payload ->> 'event_type' = ?", "revocation").count).to eq(
      205,
    )
    expect(retained.reload.source_scope_revision).to eq(205)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "rolls source revision event and scan progress back with an owned callback failure" do
    failing =
      described_class.new(
        @connection,
        clock: -> { @now },
        enqueuer: ->(args) { @queued << args },
        on_intent: ->(_intent, _config) { raise "owned callback failure" },
      )
    expect { failing.run_batch }.to raise_error(RuntimeError, "owned callback failure")
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(0)
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(@queued).to be_empty
  end

  it "creates no native record for an unmapped intent and reuses exact existing mapped work" do
    @lifecycle.refresh(topic.id)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    mapping = create_mapping
    @lifecycle.refresh(topic.id)
    work = mapping.work_items.first
    expect(work.source_revision).to eq(@store.intent(mapping.source_id).current_source_revision)
    @lifecycle.refresh(topic.id)
    expect(mapping.work_items.count).to eq(1)
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(1)
    expect(mapping.reload.desired_source_revision).to eq(work.source_revision)
  end

  it "propagates normal and wiki revisions to the same mapping and native identity" do
    mapping = create_mapping(native_id: "native:article")
    @lifecycle.refresh(topic.id)
    old = mapping.work_items.first
    old_revision = old.source_revision
    first_post.update_columns(
      raw: "A normal edit",
      cooked: "<p>A normal edit</p>",
      version: first_post.version + 1,
      updated_at: @now + 10,
    )
    @lifecycle.refresh(topic.id)
    normal = mapping.work_items.order(:id).last
    expect(old.reload.state).to eq("superseded")
    expect(normal.source_revision).not_to eq(old_revision)
    first_post.update_columns(
      raw: "A wiki edit",
      cooked: "<p>A wiki edit</p>",
      wiki: true,
      version: first_post.reload.version + 1,
      updated_at: @now + 20,
    )
    @lifecycle.refresh(topic.id)
    current = mapping.work_items.order(:id).last
    expect(normal.reload.state).to eq("superseded")
    expect(current.source_snapshot.fetch("source_updated_at")).to eq(
      DiscussionBridge::CmsProtocol.instant(@now + 20),
    )
    expect(mapping.reload.destination_native_id).to eq("native:article")
    expect(mapping.mapping_state).to eq("pending")
    expect(DiscussionBridgeCmsMapping.count).to eq(1)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(3)
  end

  it "recovers final native cooked bytes without depending on model callbacks" do
    mapping = create_mapping(native_id: "native:article")
    @lifecycle.refresh(topic.id)
    old = mapping.work_items.first
    final_body = "<p>Native post-processing settled 😀</p>"
    first_post.update_column(:cooked, final_body)
    loop { break if @lifecycle.run_batch.state == "complete" }
    current = mapping.work_items.order(:id).last
    expect(old.reload.state).to eq("superseded")
    expect(current.source_snapshot.fetch("content_sha256")).to eq(
      Digest::SHA256.hexdigest(final_body),
    )
    revision =
      @store
        .intent(mapping.source_id)
        .source_revisions
        .find_by!(source_revision: current.source_revision)
    expect(revision.content_bytes_blob.b).to eq(final_body.b)
    expect(mapping.reload.destination_native_id).to eq("native:article")
  end

  it "does not restart an identical attention cycle during unattended capture" do
    mapping = create_mapping
    @lifecycle.refresh(topic.id)
    work = mapping.work_items.first
    cycle = work.attempt_cycle
    work.update!(state: "attention", attempt: 3, last_failure_code: "public_verification_failed")
    mapping.update!(mapping_state: "attention")
    @lifecycle.refresh(topic.id)
    expect(mapping.work_items.count).to eq(1)
    expect(work.reload.state).to eq("attention")
    expect(work.attempt).to eq(3)
    expect(work.attempt_cycle).to eq(cycle)
  end

  it "cancels obsolete publication before owned withdrawal and preserves repeated withdrawal" do
    mapping = create_mapping(native_id: "native:article")
    @lifecycle.refresh(topic.id)
    publication = mapping.work_items.first
    topic.update_column(:visible, false)
    @lifecycle.refresh(topic.id)
    withdrawal = mapping.work_items.order(:id).last
    expect(publication.reload.state).to eq("cancelled")
    expect(withdrawal.action).to eq("withdraw")
    expect(withdrawal.source_revision).to be_nil
    expect(mapping.reload.destination_native_id).to eq("native:article")
    @lifecycle.refresh(topic.id)
    expect(withdrawal.reload.state).to eq("pending")
    expect(mapping.work_items.count).to eq(2)
    expect(
      DiscussionBridgeCmsSourceEvent.where("payload ->> 'event_type' = ?", "revocation").count,
    ).to eq(1)
  end

  it "leaves unknown native identity in attention without a withdrawal or second create" do
    mapping = create_mapping
    @lifecycle.refresh(topic.id)
    publication = mapping.work_items.first
    topic.update_column(:visible, false)
    @lifecycle.refresh(topic.id)
    expect(publication.reload.state).to eq("cancelled")
    expect(mapping.reload.mapping_state).to eq("attention")
    expect(mapping.destination_native_id).to be_nil
    expect(mapping.work_items.count).to eq(1)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end

  it "reports missing selected metadata without converting waiting work or assigning substitutes" do
    mapping = create_mapping
    @lifecycle.refresh(topic.id)
    work = mapping.work_items.first
    change_policy("author_ids" => ["missing-native-author"])
    value = @lifecycle.run_batch
    expect(value.state).to eq("attention")
    expect(value.error_code).to eq("catalog_entry_unavailable")
    expect(stream.lifecycle_error_code).to eq("catalog_entry_unavailable")
    expect(work.reload.state).to eq("pending")
    expect(work.attempt).to eq(0)
    expect(mapping.work_items.count).to eq(1)
    expect(@queued).to all(eq(connection_id: @connection.id.to_s))
    queued_before = @queued.length
    expect(@lifecycle.wake).to eq(true)
    expect(@queued.length).to eq(queued_before + 1)
    expect(@queued.last).to eq(connection_id: @connection.id.to_s)
  end

  it "invalidates source and mapping read snapshots durably across identical scope restoration" do
    @store.refresh_all!
    checkpoint = @store.feed("stream" => "initial").body.fetch("checkpoint_cursor")
    retained = stream
    previous_scope = retained.source_scope_revision
    read_snapshot =
      DiscussionBridgeCmsReadSnapshot.create!(
        content_connection_id: @connection.id,
        kind: "mapping_inventory",
        publication_lane: "news",
        scope_signature: "a" * 64,
        policy_revision: @configuration.fetch("policy").fetch("policy_revision"),
        item_count: 0,
        expires_at: @now + 1.day,
        created_at: @now,
      )
    described_class.invalidate_connection!(
      @connection,
      reason: "plugin_disabled",
      clock: -> { @now },
    )
    expect(retained.reload.source_scope_revision).to eq(previous_scope + 1)
    expect(retained.scan_state).to eq("uninitialized")
    expect(read_snapshot.reload.expires_at).to be <= @now
    expect { @store.feed("stream" => "changes", "cursor" => checkpoint) }.to raise_error(
      DiscussionBridge::CmsProtocol::Error,
    ) { |error| expect(error.code).to eq("cursor_scope_changed") }
    @store.refresh_all!
    expect { @store.feed("stream" => "changes", "cursor" => checkpoint) }.to raise_error(
      DiscussionBridge::CmsProtocol::Error,
    )
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(1)
  end

  it "joins invalidation to the caller's transaction and preserves terminal receipts" do
    mapping = create_mapping(native_id: "native:article")
    @lifecycle.refresh(topic.id)
    work = mapping.work_items.first
    mapping.update!(verified_result: { "retained" => "proof" })
    work.update!(state: "verified")
    before_scope = stream.source_scope_revision
    expect do
      DiscussionBridgeContentConnection.transaction do
        described_class.invalidate_connection!(
          @connection,
          reason: "scope_denied",
          clock: -> { @now },
        )
        raise "native mutation failed"
      end
    end.to raise_error(RuntimeError, "native mutation failed")
    expect(stream.source_scope_revision).to eq(before_scope)
    expect(work.reload.state).to eq("verified")
    described_class.invalidate_connection!(@connection, reason: "scope_denied", clock: -> { @now })
    expect(work.reload.state).to eq("verified")
    expect(mapping.reload.verified_result).to eq("retained" => "proof")
    expect(mapping.destination_native_id).to eq("native:article")
  end

  it "stops exhausted scope materialization without resetting retained counters" do
    mapping = create_mapping(native_id: "native:article")
    @lifecycle.refresh(topic.id)
    retained = stream
    retained.update!(source_scope_revision: DiscussionBridge::CmsProtocol::MAX_COUNTER)
    described_class.invalidate_connection!(@connection, reason: "scope_denied", clock: -> { @now })
    expect(retained.reload.source_scope_revision).to eq(DiscussionBridge::CmsProtocol::MAX_COUNTER)
    expect(retained.lifecycle_error_code).to eq("storage_exhausted")
    expect(@lifecycle.run_batch.error_code).to eq("storage_exhausted")
    expect(@lifecycle.wake).to eq(false)
    expect { @store.intent(mapping.source_id, for_mutation: true) }.to raise_error(
      DiscussionBridge::CmsProtocol::Error,
    ) { |error| expect(error.code).to eq("storage_exhausted") }
    expect(@store.intent(mapping.source_id).source_id).to eq(mapping.source_id)
    expect(mapping.work_items.count).to eq(1)
    expect(@queued).to be_empty
  end

  it "uses cooldown and persisted incompletion to recover missed enqueue without redis flags" do
    @store.refresh_all!
    expect(
      described_class.maintenance(clock: -> { @now }, enqueuer: ->(args) { @queued << args }),
    ).to eq(0)
    @now += 300
    expect(
      described_class.maintenance(clock: -> { @now }, enqueuer: ->(args) { @queued << args }),
    ).to eq(1)
    expect(@queued.last).to eq(connection_id: @connection.id.to_s)
    stream.update!(scan_state: "scanning")
    @now -= 299
    expect(
      described_class.maintenance(clock: -> { @now }, enqueuer: ->(args) { @queued << args }),
    ).to eq(1)
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(1)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "reports an actual HTTP forum source issue while preserving waiting work and native identity" do
    mapping = create_mapping(native_id: "native:article")
    @lifecycle.refresh(topic.id)
    work = mapping.work_items.first
    old_revision = work.source_revision
    SiteSetting.force_https = false
    value = @lifecycle.refresh(topic.id)
    expect(value.state).to eq("attention")
    expect(value.error_code).to eq("metadata_unavailable")
    expect(stream.lifecycle_error_code).to eq("metadata_unavailable")
    expect(work.reload.state).to eq("pending")
    expect(work.source_revision).to eq(old_revision)
    expect(mapping.reload.destination_native_id).to eq("native:article")
    expect(mapping.mapping_state).to eq("attention")
    expect(mapping.work_items.count).to eq(1)
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(1)
    expect(@queued).to be_empty
    expect(@connection.reload.cms_configuration.fetch("policy").fetch("enabled")).to eq(true)
  end

  it "rejects new materialization at event exhaustion while retaining owned read metadata" do
    @store.refresh_all!
    intent = @store.intent("topic:#{topic.id}")
    stream.update!(event_sequence: DiscussionBridge::CmsSourceStore::MAX_SEQUENCE)
    expect { @store.intent(intent.source_id, for_mutation: true) }.to raise_error(
      DiscussionBridge::CmsProtocol::Error,
    ) { |error| expect(error.code).to eq("storage_exhausted") }
    expect(@store.intent(intent.source_id).current_source_revision).to eq(
      intent.current_source_revision,
    )
    expect(stream.event_sequence).to eq(DiscussionBridge::CmsSourceStore::MAX_SEQUENCE)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "performs no source or queue mutation in native readonly mode" do
    allow(Discourse).to receive(:readonly_mode?).and_return(true)
    expect(@lifecycle.refresh(topic.id).state).to eq("inactive")
    expect(@lifecycle.run_batch.state).to eq("inactive")
    expect(@lifecycle.wake).to eq(false)
    expect(described_class.maintenance).to eq(0)
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(@queued).to be_empty
  end
end
