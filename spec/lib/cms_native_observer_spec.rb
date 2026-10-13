# frozen_string_literal: true

require "rails_helper"

# Requires root to install the coordinator and its real Plugin::Instance
# registration snippet. These examples intentionally leave source callbacks on.
describe DiscussionBridge::CmsNativeObserver do
  fab!(:admin)
  fab!(:category)

  before do
    @queued = []
    @collector = ->(args) { @queued << args.deep_dup }
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(
      :wake_connection,
    ).and_wrap_original do |method, connection_id, **options|
      method.call(connection_id, **options.merge(enqueuer: @collector))
    end
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @connection, =
      DiscussionBridgeContentConnection.issue!(
        name: "Native observer author fixture",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @configuration = {
      "profile" => "ghost",
      "destination_origin" => "https://site.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "observer-fixture:1",
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
    DiscussionBridge::CmsAuthorityStore.new(@connection).configure!(
      actor: admin,
      input: {
        "expected_policy_revision" => nil,
        "configuration" => @configuration,
      },
    )
    @connection.reload
    @store = DiscussionBridge::CmsSourceStore.new(@connection)
    @queued.clear # Ignore the separate root-owned configure/bootstrap wake.
  end

  def create_source
    PostCreator.create!(
      admin,
      {
        title: "Receiver observer native article #{SecureRandom.hex(4)}",
        raw: "A complete native first post for receiver observer author checks.",
        category: category.id,
      },
    )
  end

  def topic_wakes(topic)
    @queued.select do |args|
      args[:connection_id] == @connection.id.to_s && args[:topic_id] == topic.id.to_s
    end
  end

  def native_event_revisor(post)
    # Core emits (post, topic_changed?, revisor). A no-op revision initializes
    # the real native context without changing content or its draft sequence.
    revisor = PostRevisor.new(post)
    expect(revisor.revise!(admin, {}, keep_existing_draft: true)).to eq(false)
    revisor
  end

  def drain_wakes
    count = 0
    while args = @queued.shift
      count += 1
      raise "Unbounded observer author fixture queue" if count > 500
      connection = DiscussionBridgeContentConnection.find_by(id: args.fetch(:connection_id))
      next unless connection
      lifecycle = DiscussionBridge::CmsSourceLifecycle.new(connection, enqueuer: @collector)
      args[:topic_id] ? lifecycle.refresh(args[:topic_id]) : lifecycle.run_batch
    end
  end

  def source_intent(topic)
    @store.intent("topic:#{topic.id}")
  end

  # Receiver bookkeeping fixture, not evidence of a real Ghost object. Native
  # CMS ownership/fencing and public verification remain separate qualification.
  def owned_mapping_fixture(topic)
    record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: topic.id,
        external_id: "observer-article",
        canonical_url: "https://site.example/observer/",
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
        destination_native_id: "fixture:native:observer",
      )
    DiscussionBridge::CmsSourceLifecycle.new(@connection, enqueuer: @collector).refresh(topic.id)
    @queued.clear
    mapping
  end

  it "registers through the actual native plugin and discovers a committed native first post through queued work" do
    plugin = Discourse.plugins.find { |entry| entry.name == DiscussionBridge::PLUGIN_NAME }
    expect(plugin).to be_a(Plugin::Instance)
    post = create_source
    expect(topic_wakes(post.topic)).not_to be_empty
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    drain_wakes
    intent = source_intent(post.topic)
    expect(intent.state).to eq("active")
    expect(intent.source_revisions.first.content_bytes_blob.b).to eq(post.reload.cooked.b)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "queues native normal and wiki revisions for the same existing receiver mapping" do
    post = create_source
    drain_wakes
    mapping = owned_mapping_fixture(post.topic)
    first_work = mapping.work_items.first
    expect(
      post.revise(admin, { raw: "A changed native normal publication body for source observers." }),
    ).to eq(true)
    expect(topic_wakes(post.topic)).not_to be_empty
    drain_wakes
    normal = mapping.work_items.order(:id).last
    expect(first_work.reload.state).to eq("superseded")
    expect(normal.source_revision).not_to eq(first_work.source_revision)
    post.update!(wiki: true)
    drain_wakes
    before_wiki = mapping.work_items.order(:id).last
    expect(
      post.revise(admin, { raw: "A changed native wiki publication body for source observers." }),
    ).to eq(true)
    expect(topic_wakes(post.topic)).not_to be_empty
    drain_wakes
    wiki = mapping.work_items.order(:id).last
    expect(wiki.source_revision).not_to eq(before_wiki.source_revision)
    expect(before_wiki.reload.state).to eq("superseded")
    expect(wiki.source_snapshot.fetch("content_sha256")).to eq(
      Digest::SHA256.hexdigest(post.reload.cooked),
    )
    expect(wiki.source_snapshot.fetch("source_updated_at")).to eq(
      DiscussionBridge::CmsProtocol.instant(post.updated_at),
    )
    expect(mapping.reload.destination_native_id).to eq("fixture:native:observer")
    expect(DiscussionBridgeCmsMapping.count).to eq(1)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end

  it "covers model-only title and slug metadata changes through real add_model_callback registrations" do
    post = create_source
    drain_wakes
    old = source_intent(post.topic).current_source_revision
    # No invented topic_edited event: this is an ordinary native model save.
    post.topic.update!(
      title: "Changed observer native title",
      slug: "changed-observer-native-title",
    )
    expect(topic_wakes(post.topic)).not_to be_empty
    drain_wakes
    expect(source_intent(post.topic).current_source_revision).not_to eq(old)
    source = source_intent(post.topic).publication_event.payload.fetch("source")
    expect(source.fetch("title")).to eq("Changed observer native title")
    expect(source.fetch("topic_url")).to eq(Topic.url(post.topic_id, post.topic.reload.slug))
  end

  it "does not treat a reply edit or an unchanged model save as a first-post revision signal" do
    post = create_source
    drain_wakes
    old = source_intent(post.topic).current_source_revision
    reply =
      PostCreator.create!(
        admin,
        {
          topic_id: post.topic_id,
          raw: "A native reply which is not the exported first-post publication.",
        },
      )
    expect(topic_wakes(post.topic)).to be_empty
    expect(
      reply.revise(
        admin,
        { raw: "An edited native reply which still is not a first-post publication." },
      ),
    ).to eq(true)
    post.topic.save!
    post.save!
    expect(topic_wakes(post.topic)).to be_empty
    expect(source_intent(post.topic).current_source_revision).to eq(old)
  end

  it "does not deliver a wake from a native source transaction that rolls back" do
    before_count = Post.count
    expect do
      Topic.transaction do
        create_source
        raise "native source transaction rollback"
      end
    end.to raise_error(RuntimeError, "native source transaction rollback")
    expect(@queued).to be_empty
    expect(Post.count).to eq(before_count)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(0)
  end

  it "records native privacy aftermath without exposing a new private body and preserves owned withdrawal identity" do
    post = create_source
    drain_wakes
    mapping = owned_mapping_fixture(post.topic)
    publication = mapping.work_items.first
    revision = source_intent(post.topic).current_source_revision
    # Keep the actual native PM category constraint; do not bypass it.
    post.topic.update!(archetype: Archetype.private_message, category_id: nil)
    expect(topic_wakes(post.topic)).not_to be_empty
    expect { @store.content(mapping.source_id, revision) }.to raise_error(
      DiscussionBridge::CmsProtocol::Error,
    ) { |error| expect(error.code).to eq("source_ineligible") }
    drain_wakes
    expect(source_intent(post.topic).state).to eq("revoked")
    expect(publication.reload.state).to eq("cancelled")
    withdrawal = mapping.work_items.order(:id).last
    expect(withdrawal.action).to eq("withdraw")
    expect(withdrawal.source_revision).to be_nil
    expect(mapping.reload.destination_native_id).to eq("fixture:native:observer")
    revocation =
      source_intent(post.topic)
        .cms_source_stream
        .source_events
        .where("payload ->> 'event_type' = ?", "revocation")
        .last
        .payload
    expect(revocation.keys).to contain_exactly(
      "event_type",
      "source_id",
      "last_source_revision",
      "reason",
      "event_id",
      "event_sequence",
    )
  end

  it "retains the native topic identifier when native trash emits overlapping deletion signals" do
    post = create_source
    drain_wakes
    id = post.topic_id.to_s
    post.topic.trash!(admin)
    expect(@queued.map { |args| args[:topic_id] }).to include(id)
    drain_wakes
    expect(@store.intent("topic:#{id}").state).to eq("revoked")
    expect(DiscussionBridgeCmsSourceRevision.count).to be >= 1
  end

  it "covers first-post hidden state through a native model callback without an invented hidden event" do
    post = create_source
    drain_wakes
    revision = source_intent(post.topic).current_source_revision
    post.update!(hidden: true)
    expect(topic_wakes(post.topic)).not_to be_empty
    expect { @store.content("topic:#{post.topic_id}", revision) }.to raise_error(
      DiscussionBridge::CmsProtocol::Error,
    )
    drain_wakes
    expect(source_intent(post.topic).state).to eq("revoked")
  end

  it "observes native SharedDraft membership creation and removal through actual model callbacks" do
    post = create_source
    drain_wakes
    draft = SharedDraft.create!(topic: post.topic, category: category)
    expect(topic_wakes(post.topic)).not_to be_empty
    drain_wakes
    expect(source_intent(post.topic).state).to eq("revoked")
    draft.destroy!
    expect(topic_wakes(post.topic)).not_to be_empty
    drain_wakes
    expect(source_intent(post.topic).state).to eq("active")
    expect(source_intent(post.topic).source_id).to eq("topic:#{post.topic_id}")
  end

  it "observes native TopicEmbed membership without creating a source from imported content" do
    post = create_source
    drain_wakes
    TopicEmbed.create!(
      topic: post.topic,
      post: post,
      embed_url: "https://native.example/observer-source",
    )
    expect(topic_wakes(post.topic)).not_to be_empty
    drain_wakes
    expect(source_intent(post.topic).state).to eq("revoked")
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "captures prior and current native TopicEmbed identities when native membership moves" do
    first = create_source
    second = create_source
    drain_wakes
    embed =
      TopicEmbed.create!(
        topic: first.topic,
        post: first,
        embed_url: "https://native.example/observer-moving-source",
      )
    drain_wakes
    expect(source_intent(first.topic).state).to eq("revoked")
    expect(source_intent(second.topic).state).to eq("active")
    embed.update!(topic: second.topic, post: second)
    ids = @queued.filter_map { |args| args[:topic_id] }.uniq
    expect(ids).to contain_exactly(first.topic_id.to_s, second.topic_id.to_s)
    drain_wakes
    expect(source_intent(first.topic).state).to eq("active")
    expect(source_intent(second.topic).state).to eq("revoked")
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "queues bounded connection scans for real native category changes and documented user events" do
    category.update!(name: "Observer category metadata changed")
    expect(
      @queued.any? { |args| args[:connection_id] == @connection.id.to_s && !args.key?(:topic_id) },
    ).to eq(true)
    @queued.clear
    DiscourseEvent.trigger(:user_updated, admin)
    expect(
      @queued.any? { |args| args[:connection_id] == @connection.id.to_s && !args.key?(:topic_id) },
    ).to eq(true)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(@queued.all? { |args| (args.keys - %i[connection_id topic_id]).empty? }).to eq(true)
  end

  it "rechecks policy off, connection disable and native readonly before a direct documented event can queue" do
    post = create_source
    revisor = native_event_revisor(post)
    drain_wakes
    config = @configuration.deep_dup
    config.fetch("policy")["enabled"] = false
    DiscussionBridge::CmsAuthorityStore.new(@connection).configure!(
      actor: admin,
      input: {
        "expected_policy_revision" =>
          @connection.reload.cms_configuration.dig("policy", "policy_revision"),
        "configuration" => config,
      },
    )
    @queued.clear
    DiscourseEvent.trigger(:post_edited, post, false, revisor)
    expect(@queued).to be_empty
    config.fetch("policy")["enabled"] = true
    DiscussionBridge::CmsAuthorityStore.new(@connection).configure!(
      actor: admin,
      input: {
        "expected_policy_revision" =>
          @connection.reload.cms_configuration.dig("policy", "policy_revision"),
        "configuration" => config,
      },
    )
    @connection.update!(enabled: false)
    @queued.clear
    DiscourseEvent.trigger(:post_edited, post, false, revisor)
    expect(@queued).to be_empty
    @connection.update!(enabled: true)
    @queued.clear
    allow(Discourse).to receive(:readonly_mode?).and_return(true)
    DiscourseEvent.trigger(:post_edited, post, false, revisor)
    expect(@queued).to be_empty
  end

  it "honors the native enabled wrapper and both global receiver gates for documented source events" do
    post = create_source
    revisor = native_event_revisor(post)
    drain_wakes
    %i[
      discussion_bridge_endpoint_enabled
      discussion_bridge_publisher_enabled
      discussion_bridge_enabled
    ].each do |setting|
      SiteSetting.public_send("#{setting}=", false)
      @queued.clear
      DiscourseEvent.trigger(:post_edited, post, false, revisor, :ignored_native_trailing_argument)
      expect(@queued).to be_empty
      SiteSetting.public_send("#{setting}=", true)
      @queued.clear
    end
  end

  it "keeps duplicate documented events harmless without claiming exactly-once dispatch" do
    post = create_source
    revisor = native_event_revisor(post)
    drain_wakes
    count = DiscussionBridgeCmsSourceEvent.count
    2.times { DiscourseEvent.trigger(:post_edited, post, false, revisor) }
    expect(topic_wakes(post.topic).length).to be >= 2
    drain_wakes
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(count)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "leaves callback-bypassing persisted cooking changes to bounded receiver reconciliation" do
    post = create_source
    drain_wakes
    old = source_intent(post.topic).current_source_revision
    final_body = "<p>Final native persisted cooked output 😀</p>"
    post.update_column(:cooked, final_body)
    expect(topic_wakes(post.topic)).to be_empty
    expect(source_intent(post.topic).current_source_revision).to eq(old)
    # Directly execute the scheduled receiver operation; no sleep or fake event.
    batches = 0
    loop do
      batches += 1
      raise "Unbounded persisted cooked reconciliation" if batches > 500
      value = DiscussionBridge::CmsSourceLifecycle.new(@connection, enqueuer: @collector).run_batch
      expect(%w[scanning complete]).to include(value.state)
      break if value.state == "complete"
    end
    expect(source_intent(post.topic).current_source_revision).not_to eq(old)
    expect(source_intent(post.topic).source_revisions.order(:id).last.content_bytes_blob.b).to eq(
      final_body.b,
    )
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end
end
