# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsWorkCoordinator do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @now = Time.current
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS author native fixture",
        platform: "hugo",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @policy = {
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
    }
    @connection.update!(
      cms_configuration: {
        "profile" => "hugo",
        "destination_origin" => "https://site.example",
        "publication_lane" => "news",
        "native_capabilities" => {
          "native_revision" => "native:1",
          "supported_presentations" => ["simple"],
          "publication_kind" => "dynamic",
          "complete_content_supported" => true,
        },
        "policy" => @policy,
      },
    )
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
    @mapping =
      DiscussionBridgeCmsMapping.create!(
        mapping_id: SecureRandom.uuid,
        content_connection: @connection,
        content_binding: record.active_binding("presentation"),
        source_id: "topic:#{topic.id}",
        mapping_revision: SecureRandom.uuid,
      )
    @coordinator = described_class.new(@connection, clock: -> { @now })
    @work = @coordinator.enqueue!(@mapping, source_snapshot: snapshot)
  end

  def snapshot
    DiscussionBridge::CmsSourceStore
      .new(@connection, clock: -> { @now })
      .capture_snapshot(topic)
      .metadata
  end

  def claim
    @claim_request = { "mutation_id" => SecureRandom.uuid, "mapping_id" => @mapping.mapping_id }
    @lease = @coordinator.claim(@claim_request).body
    @authority = {
      "work_id" => @lease.fetch("work").fetch("work_id"),
      "lease_token" => @lease.fetch("lease_token"),
      "lease_generation" => @lease.fetch("lease_generation"),
      "source_revision" => @lease.fetch("work").fetch("source_revision"),
      "policy_revision" => @lease.fetch("work").fetch("policy_revision"),
    }
  end

  def native_result
    {
      "kind" => @work.action,
      "native_id" => "native:article",
      "external_id" => "article",
      "canonical_url" => "https://site.example/article/",
      "native_revision" => "native:1",
      "ownership_receipt_sha256" => "a" * 64,
      "representation" => {
        "kind" => "full",
        "source_content_sha256" => @work.source_snapshot.fetch("content_sha256"),
      },
    }
  end

  def verification
    {
      "kind" => "published",
      "url" => "https://site.example/article/",
      "native_id" => "native:article",
      "source_revision" => @work.source_revision,
      "source_content_sha256" => @work.source_snapshot.fetch("content_sha256"),
      "native_publication_sha256" => "b" * 64,
      "verification_profile" => "author-fixture:1",
      "checked_at" => DiscussionBridge::CmsProtocol.instant(@now),
      "representation" => native_result.fetch("representation"),
    }
  end

  def request(fields)
    { "mutation_id" => SecureRandom.uuid, "authority" => @authority }.merge(fields)
  end

  def rejected(code, &block)
    expect(&block).to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq(code)
    }
  end

  def static!
    config = @connection.cms_configuration.deep_dup
    config["policy"]["publication_kind"] = "static"
    config["native_capabilities"]["publication_kind"] = "static"
    @connection.update!(cms_configuration: config)
  end

  def prepare
    @transaction_id = SecureRandom.uuid
    @prepared =
      request(
        "transaction_id" => @transaction_id,
        "native_result" => native_result,
        "prepared_at" => DiscussionBridge::CmsProtocol.instant(@now),
      )
    @coordinator.prepare(@work.work_id, @prepared)
  end

  it "claims once, atomically replays the same lease, and hides secrets at rest and in status" do
    claim
    expect(@coordinator.claim(@claim_request).body).to eq(@lease)
    expect(@work.reload.attempt).to eq(1)
    expect(@mapping.reload.fence_generation).to eq(1)
    receipt = DiscussionBridgeCmsMutationReceipt.first
    expect(receipt.attributes.to_json).not_to include(@lease.fetch("lease_token"))
    expect(@work.lease_verifier).to eq(Digest::SHA256.hexdigest(@lease.fetch("lease_token")))
    expect(@coordinator.query(@work.work_id).body.to_json).not_to include(
      @lease.fetch("lease_token"),
      "lease_token",
    )
  end

  it "records and replays a no-work claim without making a later mutation under that ID" do
    @work.update!(state: "attention")
    input = { "mutation_id" => SecureRandom.uuid }
    expect(@coordinator.claim(input).status).to eq(204)
    @work.update!(state: "pending")
    expect(@coordinator.claim(input).status).to eq(204)
    expect(@work.reload.attempt).to eq(0)
    expect(@coordinator.claim({ "mutation_id" => SecureRandom.uuid }).status).to eq(200)
  end

  it "rejects changed replay payloads and foreign resources without changing counters" do
    claim
    rejected("mutation_conflict") { @coordinator.claim(@claim_request.except("mapping_id")) }
    stranger, =
      DiscussionBridgeContentConnection.issue!(
        @connection
          .attributes
          .slice(
            "platform",
            "allowed_origins",
            "allowed_directions",
            "allowed_lanes",
            "cms_configuration",
          )
          .merge("name" => "Other"),
      )
    rejected("resource_not_found") { described_class.new(stranger).query(@work.work_id) }
    expect(@work.reload.attempt).to eq(1)
  end

  it "renews unchanged authority and rejects a mismatching path or generation" do
    claim
    @now += 100
    result = @coordinator.renew(@work.work_id, request({}))
    expect(result.body.fetch("lease_token")).to eq(@lease.fetch("lease_token"))
    expect(@work.reload.attempt).to eq(1)
    rejected("identity_conflict") { @coordinator.renew(SecureRandom.uuid, request({})) }
    @authority["lease_generation"] += 1
    rejected("lease_conflict") { @coordinator.renew(@work.work_id, request({})) }
  end

  it "rechecks a connection secret rotated after request authentication and before the mutation lock" do
    authenticated =
      described_class.new(
        @connection,
        clock: -> { @now },
        authenticated_secret_digest: @connection.secret_digest,
      )
    @connection.rotate_secret!
    rejected("authentication_failed") do
      authenticated.claim({ "mutation_id" => SecureRandom.uuid })
    end
    rejected("authentication_failed") { authenticated.query(@work.work_id) }
    expect(@work.reload.attempt).to eq(0)
    expect(DiscussionBridgeCmsMutationReceipt.count).to eq(0)
  end

  it "keeps disabled publishing from creating work authority" do
    SiteSetting.discussion_bridge_publisher_enabled = false
    rejected("scope_denied") { @coordinator.claim({ "mutation_id" => SecureRandom.uuid }) }
    expect(@work.reload.attempt).to eq(0)
  end

  it "leaves waiting work unchanged when selected metadata is unavailable and returns an empty claim" do
    config = @connection.cms_configuration.deep_dup
    config["policy"]["author_ids"] = ["missing-native-author"]
    @connection.update!(cms_configuration: config)
    work_before = @work.reload.attributes.deep_dup
    fence_before = @mapping.reload.fence_generation
    count_before = DiscussionBridgeCmsWork.count
    result = @coordinator.claim({ "mutation_id" => SecureRandom.uuid })
    expect(result.status).to eq(204)
    expect(result.body).to be_nil
    expect(@work.reload.attributes).to eq(work_before)
    expect(@mapping.reload.fence_generation).to eq(fence_before)
    expect(DiscussionBridgeCmsWork.count).to eq(count_before)
    expect(@connection.reload.cms_configuration.fetch("policy").fetch("author_ids")).to eq(
      ["missing-native-author"],
    )
  end

  it "enforces expiry, receiver retry delays and three attempts without resetting the mapping fence" do
    claim
    original_authority = @authority.deep_dup
    @now += 301
    rejected("lease_expired") { @coordinator.renew(@work.work_id, request({})) }
    expect(@coordinator.claim({ "mutation_id" => SecureRandom.uuid }).status).to eq(204)
    @now += 29
    claim
    expect(@work.reload.attempt).to eq(2)
    expect(@lease.fetch("lease_generation")).to eq(2)
    rejected("lease_conflict") do
      @coordinator.renew(@work.work_id, request({}).merge("authority" => original_authority))
    end
    @now += 420
    claim
    expect(@work.reload.attempt).to eq(3)
    @now += 301
    expect(@coordinator.claim({ "mutation_id" => SecureRandom.uuid }).status).to eq(204)
    expect(@work.reload.state).to eq("attention")
    expect(@mapping.reload.fence_generation).to eq(3)
  end

  it "does not let caller retry hints make permanent public verification failure transient" do
    claim
    rejected("invalid_field") do
      @coordinator.fail(
        @work.work_id,
        request(
          "code" => "public_verification_failed",
          "native_change_applied" => true,
          "safe_detail" => "unsafe detail",
          "retry_after_seconds" => 30,
        ),
      )
    end
    @coordinator.fail(
      @work.work_id,
      request(
        "code" => "public_verification_failed",
        "native_change_applied" => true,
        "safe_detail" => @secret,
        "retry_after_seconds" => nil,
      ),
    )
    expect(@work.reload.state).to eq("attention")
    expect(@work.failure_detail.to_json).not_to include(@secret)
  end

  it "separates dynamic synchronization from verification and replays terminal receipts after lease expiry" do
    claim
    @coordinator.acknowledge(
      @work.work_id,
      request("stage" => "synchronized", "native_result" => native_result),
    )
    expect(@mapping.reload.mapping_state).to eq("pending")
    @now += 1
    verified = request("stage" => "verified", "verification" => verification)
    original = @coordinator.acknowledge(@work.work_id, verified)
    expect(@mapping.reload.mapping_state).to eq("active")
    @now += 400
    expect(@coordinator.acknowledge(@work.work_id, verified).body).to eq(original.body)
    @connection.update!(enabled: false)
    rejected("connection_disabled") { @coordinator.acknowledge(@work.work_id, verified) }
  end

  it "does not admit a new native identity or wrong content verification" do
    claim
    rejected("identity_conflict") do
      @coordinator.acknowledge(
        @work.work_id,
        request(
          "stage" => "synchronized",
          "native_result" => native_result.merge("external_id" => "other"),
        ),
      )
    end
    @coordinator.acknowledge(
      @work.work_id,
      request("stage" => "synchronized", "native_result" => native_result),
    )
    wrong_verification =
      verification.merge(
        "source_content_sha256" => "c" * 64,
        "representation" => {
          "kind" => "full",
          "source_content_sha256" => "c" * 64,
        },
      )
    rejected("content_hash_mismatch") do
      @coordinator.acknowledge(
        @work.work_id,
        request("stage" => "verified", "verification" => wrong_verification),
      )
    end
    expect(@work.reload.state).to eq("synchronized")
    expect(@mapping.reload.publicly_verified_at).to be_nil
  end

  it "requires static preparation and exact action-matching finalize rather than verified acknowledgement" do
    static!
    claim
    rejected("invalid_transition") do
      @coordinator.acknowledge(
        @work.work_id,
        request("stage" => "verified", "verification" => verification),
      )
    end
    prepare
    expect(@work.reload.state).to eq("synchronized")
    expect(@mapping.reload.publicly_verified_at).to be_nil
    rejected("invalid_transition") do
      @coordinator.finalize(
        @work.work_id,
        request(
          "transaction_id" => SecureRandom.uuid,
          "deployment_id" => "build:1",
          "deployed_at" => DiscussionBridge::CmsProtocol.instant(@now),
          "verification" => verification,
        ),
      )
    end
    @now += 1
    @coordinator.finalize(
      @work.work_id,
      request(
        "transaction_id" => @transaction_id,
        "deployment_id" => "build:1",
        "deployed_at" => DiscussionBridge::CmsProtocol.instant(@now),
        "verification" => verification,
      ),
    )
    expect(@work.reload.state).to eq("verified")
    expect(@mapping.reload.prepared_transaction).to be_nil
  end

  it "keeps failed static restoration in attention with the owned identity and reservations retained" do
    static!
    claim
    prepare
    @coordinator.abort(
      @work.work_id,
      request(
        "transaction_id" => @transaction_id,
        "native_restored" => false,
        "safe_detail" => nil,
      ),
    )
    expect(@work.reload.state).to eq("attention")
    expect(@work.last_failure_code).to eq("native_restore_required")
    expect(@mapping.reload.destination_native_id).to eq("native:article")
    expect(@mapping.prepared_transaction.fetch("transaction_id")).to eq(@transaction_id)
    expect(@mapping.content_binding.canonical_url).to eq("https://site.example/article/")
  end

  it "invalidates prior source work and advances the mapping fence across a new work UUID" do
    claim
    first_post.update!(
      cooked: "<p>new immutable source revision</p>",
      raw: "new immutable source revision",
    )
    new_work = @coordinator.enqueue!(@mapping, source_snapshot: snapshot)
    expect(@work.reload.state).to eq("superseded")
    expect(new_work.work_id).not_to eq(@work.work_id)
    @work = new_work
    claim
    expect(@lease.fetch("lease_generation")).to eq(2)
    expect(@work.reload.attempt).to eq(1)
  end

  it "rebinds the same prepared native transaction after an expired lease with fresh generation provenance" do
    static!
    claim
    prepare
    old_authority = @authority.deep_dup
    previous = @mapping.reload.prepared_transaction.deep_dup
    @now += 331
    claim
    expect(@lease.fetch("lease_generation")).to eq(2)
    expect(@work.reload.attempt).to eq(2)
    rebound = native_result.merge("ownership_receipt_sha256" => "c" * 64)
    @coordinator.prepare(
      @work.work_id,
      request(
        "transaction_id" => @transaction_id,
        "native_result" => rebound,
        "prepared_at" => DiscussionBridge::CmsProtocol.instant(@now),
      ),
    )
    current = @mapping.reload.prepared_transaction
    expect(current.fetch("transaction_id")).to eq(previous.fetch("transaction_id"))
    expect(current.fetch("lease_generation")).to eq(2)
    expect(current.fetch("native_result")).to eq(rebound)
    rejected("lease_conflict") do
      @coordinator.renew(@work.work_id, request({}).merge("authority" => old_authority))
    end
    expect(@mapping.publicly_verified_at).to be_nil
  end

  it "holds a new source revision in attention while a different static transaction remains open" do
    static!
    claim
    prepare
    old_authority = @authority.deep_dup
    transaction = @mapping.reload.prepared_transaction.deep_dup
    first_post.update!(raw: "Changed while native staging remains uncertain")
    current = @coordinator.enqueue!(@mapping, source_snapshot: snapshot)
    expect(@work.reload.state).to eq("superseded")
    expect(current.state).to eq("attention")
    expect(current.last_failure_code).to eq("native_restore_required")
    expect(current.attempt).to eq(0)
    expect(@mapping.reload.mapping_state).to eq("attention")
    expect(@mapping.prepared_transaction).to eq(transaction)
    expect(@mapping.fence_generation).to eq(1)
    expect(@coordinator.claim({ "mutation_id" => SecureRandom.uuid }).status).to eq(204)
    rejected("work_superseded") do
      @coordinator.finalize(
        @work.work_id,
        request(
          "transaction_id" => @transaction_id,
          "deployment_id" => "stale-build",
          "deployed_at" => DiscussionBridge::CmsProtocol.instant(@now),
          "verification" => verification,
        ).merge("authority" => old_authority),
      )
    end
  end

  it "rejects a first native identity already retained by another owned mapping" do
    other_topic = Fabricate(:topic, user: admin)
    Fabricate(:post, topic: other_topic, user: admin, post_number: 1)
    record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: other_topic.id,
        external_id: "retained-native",
        canonical_url: "https://site.example/retained-native/",
        lane: "news",
        native_materialization: true,
        presentation_mode: "simple",
      ).record
    retained =
      DiscussionBridgeCmsMapping.create!(
        mapping_id: SecureRandom.uuid,
        content_connection: @connection,
        content_binding: record.active_binding("presentation"),
        source_id: "topic:#{other_topic.id}",
        mapping_revision: SecureRandom.uuid,
        destination_native_id: "native:article",
        mapping_state: "withdrawn",
      )
    claim
    before = [
      @mapping.reload.attributes.deep_dup,
      @work.reload.attributes.deep_dup,
      retained.attributes.deep_dup,
      DiscussionBridgeCmsMutationReceipt.count,
    ]
    rejected("native_ownership_conflict") do
      @coordinator.acknowledge(
        @work.work_id,
        request("stage" => "synchronized", "native_result" => native_result),
      )
    end
    expect(
      [
        @mapping.reload.attributes,
        @work.reload.attributes,
        retained.reload.attributes,
        DiscussionBridgeCmsMutationReceipt.count,
      ],
    ).to eq(before)
  end

  it "settles expired leases and due retries without a claim, preserving exact cycle and counters" do
    claim
    cycle = @work.reload.attempt_cycle
    expiry = @work.lease_expires_at
    counts = [
      DiscussionBridgeCmsWork.count,
      DiscussionBridgeCmsSourceIntent.count,
      DiscussionBridgeCmsMutationReceipt.count,
    ]
    @now = expiry
    expect(@coordinator.maintain_due!).to eq(1)
    expect(@work.reload.state).to eq("retry_wait")
    expect(@work.retry_at).to eq(expiry + 30)
    expect(@work.lease_verifier).to be_nil
    expect(@work.lease_expires_at).to be_nil
    expect(@work.attempt).to eq(1)
    expect(@work.attempt_cycle).to eq(cycle)
    expect(@mapping.reload.fence_generation).to eq(1)
    @now = expiry + 29
    expect(@coordinator.maintain_due!).to eq(0)
    @now = expiry + 30
    expect(@coordinator.maintain_due!).to eq(1)
    expect(@work.reload.state).to eq("pending")
    expect(@work.retry_at).to be_nil
    expect(@work.attempt_cycle).to eq(cycle)
    expect(@work.attempt).to eq(1)
    expect(
      [
        DiscussionBridgeCmsWork.count,
        DiscussionBridgeCmsSourceIntent.count,
        DiscussionBridgeCmsMutationReceipt.count,
      ],
    ).to eq(counts)
    expect(@mapping.reload.fence_generation).to eq(1)
  end

  it "uses the actual expiry for late maintenance and leaves exhausted native staging in attention" do
    static!
    claim
    prepare
    transaction = @mapping.reload.prepared_transaction.deep_dup
    @now = @work.reload.lease_expires_at + 31
    expect(@coordinator.maintain_due!).to eq(1)
    expect(@work.reload.state).to eq("pending")
    expect(@work.attempt).to eq(1)
    expect(@mapping.reload.prepared_transaction).to eq(transaction)
    claim
    @now = @work.reload.lease_expires_at + 119
    @coordinator.maintain_due!
    expect(@work.reload.state).to eq("retry_wait")
    @now += 1
    @coordinator.maintain_due!
    expect(@work.reload.state).to eq("pending")
    claim
    cycle = @work.reload.attempt_cycle
    @now = @work.lease_expires_at + 600
    @coordinator.maintain_due!
    expect(@work.reload.state).to eq("attention")
    expect(@work.attempt).to eq(3)
    expect(@work.attempt_cycle).to eq(cycle)
    expect(@work.last_failure_code).to eq("transport_timeout")
    expect(@mapping.reload.mapping_state).to eq("attention")
    expect(@mapping.prepared_transaction).to eq(transaction)
    expect(@mapping.fence_generation).to eq(3)
    expect(@coordinator.maintain_due!).to eq(0)
    expect(@coordinator.claim({ "mutation_id" => SecureRandom.uuid }).status).to eq(204)
  end

  it "does not settle work while publishing is off or native storage is readonly" do
    claim
    @now = @work.reload.lease_expires_at + 1
    before = @work.attributes.deep_dup
    allow(Discourse).to receive(:readonly_mode?).and_return(true)
    expect(@coordinator.maintain_due!).to eq(0)
    expect(described_class.maintenance(clock: -> { @now })).to eq(0)
    expect(@work.reload.attributes).to eq(before)
    allow(Discourse).to receive(:readonly_mode?).and_return(false)
    SiteSetting.discussion_bridge_publisher_enabled = false
    expect(@coordinator.maintain_due!).to eq(0)
    expect(@work.reload.attributes).to eq(before)
  end

  it "settles actual existing expiry through the native scheduled dispatcher without source discovery" do
    claim
    expiry = Time.current.change(usec: 0) - 2
    @work.update!(lease_expires_at: expiry)
    cycle = @work.attempt_cycle
    counts = [
      DiscussionBridgeCmsWork.count,
      DiscussionBridgeCmsSourceIntent.count,
      DiscussionBridgeCmsMutationReceipt.count,
    ]
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:maintenance).and_return(0)
    Jobs::DiscussionBridgeCmsLifecycleMaintenance.new.execute({})
    expect(@work.reload.state).to eq("retry_wait")
    expect(@work.retry_at).to eq(expiry + 30)
    expect(@work.attempt_cycle).to eq(cycle)
    expect(@work.attempt).to eq(1)
    expect(@mapping.reload.fence_generation).to eq(1)
    expect(
      [
        DiscussionBridgeCmsWork.count,
        DiscussionBridgeCmsSourceIntent.count,
        DiscussionBridgeCmsMutationReceipt.count,
      ],
    ).to eq(counts)
  end

  it "bounds timer work without settling another connection or resetting attention and terminal records" do
    @work.update!(state: "retry_wait", retry_at: @now - 1, attempt: 1)
    other_topic = Fabricate(:topic, user: admin)
    Fabricate(:post, topic: other_topic, user: admin, post_number: 1)
    other_record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: other_topic.id,
        external_id: "another-timer-page",
        canonical_url: "https://site.example/timer-two/",
        lane: "news",
        native_materialization: true,
        presentation_mode: "simple",
      ).record
    other_mapping =
      DiscussionBridgeCmsMapping.create!(
        mapping_id: SecureRandom.uuid,
        content_connection: @connection,
        content_binding: other_record.active_binding("presentation"),
        source_id: "topic:#{other_topic.id}",
        mapping_revision: SecureRandom.uuid,
      )
    other_snapshot =
      DiscussionBridge::CmsSourceStore
        .new(@connection, clock: -> { @now })
        .capture_snapshot(other_topic)
        .metadata
    other_work = @coordinator.enqueue!(other_mapping, source_snapshot: other_snapshot)
    other_work.update!(state: "retry_wait", retry_at: @now - 1, attempt: 1)
    stranger, =
      DiscussionBridgeContentConnection.issue!(
        @connection
          .attributes
          .slice("platform", "allowed_origins", "allowed_directions", "allowed_lanes")
          .merge(
            "name" => "Foreign timer destination",
            "cms_configuration" => @connection.cms_configuration,
          ),
      )
    foreign_record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: stranger.id,
        topic_id: other_topic.id,
        external_id: "foreign-timer-page",
        canonical_url: "https://site.example/foreign-timer/",
        lane: "news",
        native_materialization: true,
        presentation_mode: "simple",
      ).record
    foreign_mapping =
      DiscussionBridgeCmsMapping.create!(
        mapping_id: SecureRandom.uuid,
        content_connection: stranger,
        content_binding: foreign_record.active_binding("presentation"),
        source_id: "topic:#{other_topic.id}",
        mapping_revision: SecureRandom.uuid,
      )
    foreign_snapshot =
      DiscussionBridge::CmsSourceStore
        .new(stranger, clock: -> { @now })
        .capture_snapshot(other_topic)
        .metadata
    foreign_work =
      described_class.new(stranger, clock: -> { @now }).enqueue!(
        foreign_mapping,
        source_snapshot: foreign_snapshot,
      )
    foreign_work.update!(state: "retry_wait", retry_at: @now - 1, attempt: 1)
    foreign_before = foreign_work.attributes.deep_dup
    expect(@coordinator.maintain_due!(limit: 1)).to eq(1)
    expect(DiscussionBridgeCmsWork.where(state: "retry_wait").count).to eq(2)
    expect(@coordinator.maintain_due!(limit: 1)).to eq(1)
    expect(DiscussionBridgeCmsWork.where(state: "retry_wait").count).to eq(1)
    expect(foreign_work.reload.attributes).to eq(foreign_before)
    @work.reload.update!(state: "attention", last_failure_code: "public_verification_failed")
    other_work.reload.update!(state: "verified")
    retained = [@work.reload.attributes.deep_dup, other_work.reload.attributes.deep_dup]
    expect(@coordinator.maintain_due!).to eq(0)
    expect([@work.reload.attributes, other_work.reload.attributes]).to eq(retained)
    expect { @coordinator.maintain_due!(limit: 0) }.to raise_error(ArgumentError)
    expect { @coordinator.maintain_due!(limit: 101) }.to raise_error(ArgumentError)
  end

  it "retains last known source dates and native ownership while materializing owned withdrawal" do
    claim
    @coordinator.acknowledge(
      @work.work_id,
      request("stage" => "synchronized", "native_result" => native_result),
    )
    created = @mapping.reload.source_created_at
    updated = @mapping.source_updated_at
    withdrawn = @coordinator.enqueue!(@mapping, source_snapshot: nil, action: "withdraw")
    expect(withdrawn.source_revision).to be_nil
    expect(@mapping.reload.source_created_at).to eq(created)
    expect(@mapping.source_updated_at).to eq(updated)
    expect(@mapping.destination_native_id).to eq("native:article")
    expect(@mapping.native_result).to eq(native_result)
    expect(@mapping.synchronized_source_revision).to eq(@work.source_revision)
    expect(@mapping.mapping_state).to eq("pending")
  end
end
