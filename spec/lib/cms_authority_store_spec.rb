# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsAuthorityStore do
  fab!(:admin)
  fab!(:user)
  fab!(:moderator)

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS native authority fixture",
        platform: "ghost",
        author_user_id: admin.id,
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @configuration = {
      "profile" => "ghost",
      "destination_origin" => "https://site.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "native:fixture",
        "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic",
        "complete_content_supported" => true,
      },
      "policy" => {
        "enabled" => false,
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
    @store = described_class.new(@connection)
  end

  def write(
    configuration = @configuration,
    expected: @connection.reload.cms_configuration&.dig("policy", "policy_revision"),
    actor: admin
  )
    @store.configure!(
      actor: actor,
      input: {
        "expected_policy_revision" => expected,
        "configuration" => configuration,
      },
    )
  end

  def audit_count
    DB.query_single("SELECT count(*) FROM discussion_bridge_cms_configuration_events").first.to_i
  end

  def rejected(code, &block)
    expect(&block).to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq(code)
    }
  end

  def native_work(state: "leased")
    topic = Fabricate(:topic, user: admin)
    first_post = Fabricate(:post, topic: topic, user: admin, post_number: 1)
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
    mapping =
      DiscussionBridgeCmsMapping.create!(
        mapping_id: SecureRandom.uuid,
        content_connection: @connection,
        content_binding: record.active_binding("presentation"),
        source_id: "topic:#{topic.id}",
        mapping_revision: SecureRandom.uuid,
        fence_generation: 2,
        mapping_state: "active",
        publicly_verified_source_revision: "prior-revision",
      )
    work =
      mapping.work_items.create!(
        work_id: SecureRandom.uuid,
        source_revision: "prior-revision",
        policy_revision: @connection.cms_configuration.dig("policy", "policy_revision"),
        action: "publish_revision",
        state: state,
        attempt_cycle: SecureRandom.uuid,
        attempt: 1,
        lease_generation: 2,
        lease_verifier: "a" * 64,
        lease_expires_at: 5.minutes.from_now,
      )
    [work, mapping, record, first_post]
  end

  it "never invents an absent configuration or creates source/mapping/work through descriptor reads" do
    expect(@store.administrative_configuration(actor: admin).body).to eq("cms_configuration" => nil)
    rejected("scope_denied") { @store.descriptor }
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(DiscussionBridgeCmsMapping.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(audit_count).to eq(0)
  end

  it "stores explicit off policy with receiver revision and one secret-free private native audit" do
    result = write
    configuration = result.body.fetch("cms_configuration")
    revision = configuration.fetch("policy").fetch("policy_revision")
    DiscussionBridge::CmsProtocol.validate!("Revision", revision)
    expect(configuration.fetch("policy").fetch("enabled")).to eq(false)
    expect(@connection.reload.cms_configuration).to eq(configuration)
    expect(audit_count).to eq(1)
    expect(
      DB
        .query_single("SELECT actor_user_id FROM discussion_bridge_cms_configuration_events")
        .first
        .to_i,
    ).to eq(admin.id)
    expect(
      DB.query_single(
        "SELECT previous_policy_revision FROM discussion_bridge_cms_configuration_events",
      ).first,
    ).to eq(nil)
    audit =
      DB.query_single(
        "SELECT configuration::text FROM discussion_bridge_cms_configuration_events",
      ).first
    expect(JSON.parse(audit)).to eq(configuration)
    expect(audit).not_to include(@secret, @connection.secret_digest)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "retains exact unchanged configuration/revision without extra audit or work invalidation" do
    first = write.body.fetch("cms_configuration")
    reversed = @configuration.to_a.reverse.to_h
    reversed["policy"] = reversed.fetch("policy").to_a.reverse.to_h
    expect(write(reversed).body.fetch("cms_configuration")).to eq(first)
    expect(audit_count).to eq(1)
  end

  it "rejects stale revisions and caller-assigned revisions before changing native authority" do
    original = write.body.fetch("cms_configuration")
    rejected("revision_conflict") { write(expected: "stale-revision") }
    input = @configuration.deep_dup
    input.fetch("policy")["policy_revision"] = "caller-revision"
    rejected("unknown_field") { write(input) }
    expect(@connection.reload.cms_configuration).to eq(original)
    expect(audit_count).to eq(1)
  end

  it "requires an active native administrator, not moderator/user/caller capabilities" do
    [nil, user, moderator].each do |actor|
      expect { write(actor: actor) }.to raise_error(Discourse::InvalidAccess)
    end
    admin.update!(active: false)
    expect { write }.to raise_error(Discourse::InvalidAccess)
    expect(@connection.reload.cms_configuration).to eq(nil)
    expect(audit_count).to eq(0)
  end

  it "refuses unknown fields, wrong native scope and unsupported selected presentation" do
    input = @configuration.deep_dup
    input["connection_secret"] = @secret
    rejected("unknown_field") { write(input) }
    input = @configuration.deep_dup
    input["destination_origin"] = "https://other.example"
    rejected("scope_denied") { write(input) }
    input = @configuration.deep_dup
    input["profile"] = "wordpress"
    rejected("scope_denied") { write(input) }
    input = @configuration.deep_dup
    input["publication_lane"] = "other"
    rejected("scope_denied") { write(input) }
    input = @configuration.deep_dup
    input.fetch("native_capabilities")["supported_presentations"] = ["full"]
    rejected("presentation_unsupported") { write(input) }
    expect(audit_count).to eq(0)
  end

  it "reads truthful descriptors with publishing off and reuses native source scope fingerprint" do
    stored = write.body.fetch("cms_configuration")
    SiteSetting.discussion_bridge_publisher_enabled = false
    descriptor = @store.descriptor.body
    DiscussionBridge::CmsProtocol.validate!("Connection", descriptor)
    expect(descriptor.fetch("forum_name")).to eq(SiteSetting.title)
    expect(descriptor.fetch("directions")).to eq(["from_discourse"])
    expect(descriptor.fetch("policy")).to eq(stored.fetch("policy"))
    expect(descriptor.fetch("native_capabilities")).to eq(
      @configuration.fetch("native_capabilities"),
    )
    expected =
      DiscussionBridge::CmsSourceStore.new(@connection).scope_fingerprint(
        stored,
        source_scope_revision: 0,
      )
    expect(descriptor.fetch("scope_revision")).to eq(expected)
    expect(@store.publication_policy.body).to eq(stored.fetch("policy"))
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(audit_count).to eq(1)
  end

  it "binds descriptor scope to existing privacy revision without changing stream or inventing source work" do
    write
    stream =
      DiscussionBridgeCmsSourceStream.create!(
        content_connection: @connection,
        publication_lane: "news",
        source_scope_revision: 3,
      )
    previous = @store.descriptor.body.fetch("scope_revision")
    stream.update!(source_scope_revision: 4)
    expect(@store.descriptor.body.fetch("scope_revision")).not_to eq(previous)
    expect(stream.reload.source_scope_revision).to eq(4)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "lets an explicitly configured To-only connection read descriptors without From enablement" do
    @connection.update!(allowed_directions: ["to_discourse"])
    write
    expect(@store.descriptor.body.fetch("directions")).to eq(["to_discourse"])
    expect(@store.publication_policy.body.fetch("enabled")).to eq(false)
    enabled = @configuration.deep_dup
    enabled.fetch("policy")["enabled"] = true
    rejected("scope_denied") { write(enabled) }
    expect(@connection.reload.cms_configuration.fetch("policy").fetch("enabled")).to eq(false)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "does not borrow a previous lane's privacy counter after native configuration changes lanes" do
    write
    DiscussionBridgeCmsSourceStream.create!(
      content_connection: @connection,
      publication_lane: "news",
      source_scope_revision: 9,
    )
    @connection.update!(allowed_lanes: %w[news other])
    changed = @configuration.deep_dup
    changed["publication_lane"] = "other"
    stored = write(changed).body.fetch("cms_configuration")
    expected =
      DiscussionBridge::CmsSourceStore.new(@connection).scope_fingerprint(
        stored,
        source_scope_revision: 0,
      )
    expect(@store.descriptor.body.fetch("scope_revision")).to eq(expected)
    expect(DiscussionBridgeCmsSourceStream.count).to eq(1)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "rechecks rotated credentials and disabled connection on descriptor access" do
    write
    reader =
      described_class.new(@connection, authenticated_secret_digest: @connection.secret_digest)
    @connection.rotate_secret!
    rejected("authentication_failed") { reader.descriptor }
    @connection.update!(enabled: false)
    rejected("connection_disabled") { @store.publication_policy }
  end

  it "keeps unavailable explicit catalog selections instead of inventing native defaults" do
    input = @configuration.deep_dup
    input.fetch("policy").merge!(
      "enabled" => true,
      "author_ids" => ["unavailable-author"],
      "taxonomy_ids" => ["unavailable-taxonomy"],
    )
    stored = write(input).body.fetch("cms_configuration")
    expect(stored.fetch("policy").fetch("author_ids")).to eq(["unavailable-author"])
    expect(@store.publication_policy.body.fetch("taxonomy_ids")).to eq(["unavailable-taxonomy"])
    rejected("catalog_entry_unavailable") do
      DiscussionBridge::CmsConfiguration.current!(@connection, require_enabled: true)
    end
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "supersedes live work on current selection change while preserving identity and verified revision" do
    enabled = @configuration.deep_dup
    enabled.fetch("policy")["enabled"] = true
    previous = write(enabled).body.fetch("cms_configuration")
    work, mapping, record, first_post = native_work
    identity = [
      mapping.mapping_id,
      mapping.content_binding_id,
      mapping.fence_generation,
      record.resource_id,
      record.topic_id,
      first_post.raw,
      first_post.cooked,
      mapping.publicly_verified_source_revision,
    ]
    enabled.fetch("policy")["include_unlisted"] = true
    changed = write(enabled).body.fetch("cms_configuration")
    expect(changed.fetch("policy").fetch("policy_revision")).not_to eq(
      previous.fetch("policy").fetch("policy_revision"),
    )
    expect(work.reload.state).to eq("superseded")
    expect(work.lease_verifier).to eq(nil)
    expect(work.lease_expires_at).to eq(nil)
    expect(work.attempt).to eq(1)
    mapping.reload
    expect(mapping.mapping_state).to eq("attention")
    expect(
      [
        mapping.mapping_id,
        mapping.content_binding_id,
        mapping.fence_generation,
        record.reload.resource_id,
        record.topic_id,
        first_post.reload.raw,
        first_post.cooked,
        mapping.publicly_verified_source_revision,
      ],
    ).to eq(identity)
    expect(audit_count).to eq(2)
  end

  it "holds previously active verification for changed presentation without replacing native identity or creating work" do
    enabled = @configuration.deep_dup
    enabled.fetch("policy")["enabled"] = true
    enabled.fetch("native_capabilities")["supported_presentations"] = %w[simple full]
    write(enabled)
    terminal, mapping, record, first_post = native_work(state: "verified")
    terminal.update!(lease_verifier: nil, lease_expires_at: nil)
    mapping.update!(
      destination_native_id: "native-article-retained",
      destination_native_revision: "native:previous",
      desired_source_revision: "desired-retained",
      synchronized_source_revision: "prior-revision",
      native_result: {
        "fixture" => "previous-native-result",
      },
      verified_result: {
        "fixture" => "previous-verification-receipt",
      },
    )
    mapping_before = mapping.attributes.except("mapping_state", "updated_at")
    work_before = terminal.attributes
    record_before = record.attributes
    content_before = [first_post.raw, first_post.cooked]

    # An identical configuration retains the current active state and audit.
    write(enabled)
    expect(mapping.reload.mapping_state).to eq("active")
    expect(audit_count).to eq(1)

    enabled.fetch("policy")["presentation_mode"] = "full"
    write(enabled)
    expect(mapping.reload.mapping_state).to eq("attention")
    expect(mapping.attributes.except("mapping_state", "updated_at")).to eq(mapping_before)
    expect(terminal.reload.attributes).to eq(work_before)
    expect(record.reload.attributes).to eq(record_before)
    expect([first_post.reload.raw, first_post.cooked]).to eq(content_before)
    expect(DiscussionBridgeCmsWork.count).to eq(1)
    expect(audit_count).to eq(2)
  end

  it "cancels uncompleted work on policy disable but retains terminal verified work" do
    enabled = @configuration.deep_dup
    enabled.fetch("policy")["enabled"] = true
    write(enabled)
    live, mapping = native_work
    terminal =
      mapping.work_items.create!(
        work_id: SecureRandom.uuid,
        source_revision: "older-revision",
        policy_revision: @connection.cms_configuration.dig("policy", "policy_revision"),
        action: "publish_revision",
        state: "verified",
        attempt_cycle: SecureRandom.uuid,
        attempt: 1,
        lease_generation: 1,
      )
    write(@configuration)
    expect(live.reload.state).to eq("cancelled")
    expect(terminal.reload.state).to eq("verified")
    expect(mapping.reload.mapping_state).to eq("attention")
    expect(mapping.reload.publicly_verified_source_revision).to eq("prior-revision")
  end

  it "holds every nonwithdrawn mapping on disable while retaining actual withdrawn state and prior evidence" do
    enabled = @configuration.deep_dup
    enabled.fetch("policy")["enabled"] = true
    write(enabled)
    terminal, mapping = native_work(state: "verified")
    terminal.update!(lease_verifier: nil, lease_expires_at: nil)
    mapping.update!(
      destination_native_id: "native-article-retained",
      verified_result: {
        "fixture" => "prior-receipt",
      },
    )
    mapping_before = mapping.attributes.except("mapping_state", "updated_at")
    work_before = terminal.attributes

    %w[pending attention withdrawn].each do |prior_state|
      write(enabled)
      mapping.update!(mapping_state: prior_state)
      write(@configuration)
      expect(mapping.reload.mapping_state).to eq(
        prior_state == "withdrawn" ? "withdrawn" : "attention",
      )
      expect(mapping.attributes.except("mapping_state", "updated_at")).to eq(mapping_before)
      expect(terminal.reload.attributes).to eq(work_before)
      expect(DiscussionBridgeCmsWork.count).to eq(1)
    end
  end

  it "rolls back configuration, work invalidation and audit together when audit persistence fails" do
    enabled = @configuration.deep_dup
    enabled.fetch("policy")["enabled"] = true
    previous = write(enabled).body.fetch("cms_configuration")
    work, mapping = native_work
    allow(DB).to receive(:exec).and_raise(StandardError, "injected private audit failure")
    expect { write(@configuration) }.to raise_error(StandardError, "injected private audit failure")
    expect(@connection.reload.cms_configuration).to eq(previous)
    expect(work.reload.state).to eq("leased")
    expect(work.lease_verifier).to eq("a" * 64)
    expect(mapping.reload.mapping_state).to eq("active")
    expect(audit_count).to eq(1)
  end
end
