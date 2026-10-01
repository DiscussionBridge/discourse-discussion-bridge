# frozen_string_literal: true

require "rails_helper"
require "pg"
require "timeout"

RSpec.describe "R3-F13 publication readiness serialization" do
  self.use_transactional_tests = false

  before do
    @workers = []
    @connection_ids = []
    @connection_public_ids = []
    @record_ids = []
    @topic_ids = []
    @users = []
    @site_settings = {
      discussion_bridge_enabled: SiteSetting.discussion_bridge_enabled,
      discussion_bridge_endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
      discussion_bridge_service_username: SiteSetting.discussion_bridge_service_username,
      discussion_bridge_effective_tags: SiteSetting.discussion_bridge_effective_tags,
      discussion_bridge_lane_policies: SiteSetting.discussion_bridge_lane_policies,
    }
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
  end

  after do
    survivors = []
    @workers.each do |worker|
      worker.kill if worker.alive?
      worker.join(5)
      survivors << worker if worker.alive?
    end
    raise "R3-F13 worker survived example cleanup" if survivors.any?

    cleanup_created_rows
    @site_settings.each { |name, value| SiteSetting.public_send("#{name}=", value) }
  end

  it "finishes admitted generation before a pending transition commits" do
    connection, record = create_source
    generation_holds_connection = Queue.new
    continue_generation = Queue.new
    generation_result = Queue.new
    pending_pid = Queue.new
    pending_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    generation_worker = start_worker(generation_result) do
      locked_connection = DiscussionBridgeContentConnection.find(connection.id)
      materializer = DiscussionBridge::SourceRevisionMaterializer.new(
        record: DiscussionBridgeBridgeRecord.find(record.id),
        connection: locked_connection,
      )
      original = materializer.method(:unavailability_reason)
      materializer.define_singleton_method(:unavailability_reason) do
        generation_holds_connection << true
        continue_generation.pop
        original.call
      end
      materializer.call
    end
    wait_for(generation_holds_connection)

    pending_worker = start_worker(pending_result) do
      pending_pid << database_pid
      set_pending!(DiscussionBridgeContentConnection.find(connection.id))
    end
    wait_for_database_lock(wait_for(pending_pid))
    continue_generation << true
    wait_for(generation_worker)
    wait_for(pending_worker)

    expect(generation_result.pop).to be_a(DiscussionBridge::SourceRevisionMaterializer::Result)
    expect(pending_result.pop).to be(true)
    expect(DiscussionBridge::ConnectionCapability.publication_readiness(connection.reload)).to eq(
      :temporarily_unavailable,
    )
    expect(record.reload.source_revisions.count).to eq(1)
    expect(record.publication_works.count).to eq(1)
  ensure
    continue_generation << true if defined?(continue_generation) && generation_worker&.alive?
  end

  it "makes generation observe pending when the transition commits first" do
    connection, record = create_source
    pending_holds_connection = Queue.new
    continue_pending = Queue.new
    pending_result = Queue.new
    generation_pid = Queue.new
    generation_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    pending_worker = start_worker(pending_result) do
      DiscussionBridgeContentConnection.transaction do
        locked_connection = DiscussionBridgeContentConnection.lock.find(connection.id)
        pending_holds_connection << true
        continue_pending.pop
        set_pending!(locked_connection)
      end
    end
    wait_for(pending_holds_connection)

    generation_worker = start_worker(generation_result) do
      generation_pid << database_pid
      DiscussionBridge::SourceRevisionMaterializer.call(
        record: DiscussionBridgeBridgeRecord.find(record.id),
        connection: DiscussionBridgeContentConnection.find(connection.id),
      )
    end
    wait_for_database_lock(wait_for(generation_pid))
    continue_pending << true
    wait_for(pending_worker)
    wait_for(generation_worker)

    expect(pending_result.pop).to be(true)
    error = generation_result.pop
    expect(error).to be_a(DiscussionBridge::AdapterRequestBoundary::Error)
    expect(error.error_code).to eq("temporarily_unavailable")
    expect(DiscussionBridge::ConnectionCapability.publication_readiness(connection.reload)).to eq(
      :temporarily_unavailable,
    )
    expect(record.reload.source_revisions).to be_empty
    expect(record.publication_works).to be_empty
  ensure
    continue_pending << true if defined?(continue_pending) && pending_worker&.alive?
  end

  private

  def create_source
    identity = SecureRandom.hex(6)
    user = Fabricate(
      :admin,
      username: "r3f13#{identity}",
      email: "r3f13#{identity}@example.com",
    )
    @users << user
    SiteSetting.discussion_bridge_service_username = user.username
    connection, = DiscussionBridgeContentConnection.issue!(
      name: "R3-F13 #{identity}",
      platform: "wordpress",
      allowed_origins: ["https://publisher.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: ["articles"],
      destination_policies: [active_policy],
      catalog_required: true,
      policy_revision: "policy:r3-f13:active",
    )
    @connection_ids << connection.id
    @connection_public_ids << connection.public_id
    topic = Fabricate(:topic, user: user, title: "R3-F13 #{identity}", visible: true)
    Fabricate(:post, topic: topic, user: user, post_number: 1, raw: "Publication body")
    @topic_ids << topic.id
    result = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: user,
      connection_id: connection.id,
      topic_id: topic.id,
      external_id: "r3-f13-#{identity}",
      canonical_url: "https://publisher.example/articles/#{identity}/",
      lane: "articles",
      native_materialization: true,
    )
    @record_ids << result.record.id
    [connection, result.record]
  end

  def active_policy
    {
      "destination_policy_id" => "destination:wordpress:articles:1",
      "profile" => "wordpress",
      "presentation_mode" => "interactive",
      "container_mapping" => {
        "source" => "discourse:category:articles",
        "destination" => "site:articles",
      },
      "taxonomy_mapping" => { "mode" => "source_attribution" },
      "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => {
        "maximum_bytes" => 49_152,
        "overflow_behavior" => "excerpt_with_read_more",
      },
      "catalog_revision" => "catalog:wordpress:r3-f13",
    }
  end

  def set_pending!(connection)
    policy = active_policy
    policy["destination_policy_id"] = "destination:wordpress:pending"
    policy["container_mapping"]["destination"] =
      DiscussionBridge::ConnectionCapability::PENDING_CATALOG_DESTINATION
    connection.update!(
      destination_policies: [policy],
      policy_revision: "policy:r3-f13:pending",
    )
  end

  def start_worker(result, &block)
    Thread.new do
      begin
        ActiveRecord::Base.connection_pool.with_connection { result << block.call }
      rescue StandardError => error
        result << error
      end
    end.tap do |worker|
      worker.report_on_exception = false
      @workers << worker
    end
  end

  def database_pid
    ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()").to_i
  end

  def wait_for(target)
    Timeout.timeout(15) do
      target.is_a?(Thread) ? target.join : target.pop
    end
  end

  def wait_for_database_lock(backend_pid)
    observer = PG.connect(dbname: ActiveRecord::Base.connection_db_config.database)
    Timeout.timeout(15) do
      loop do
        result = observer.exec_params(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
          [Integer(backend_pid)],
        )
        return if result.ntuples == 1 && result.getvalue(0, 0) == "Lock"

        sleep 0.01
      end
    end
  ensure
    observer&.close
  end

  def cleanup_created_rows
    DiscussionBridgePublicationAcknowledgement.where(publication_work_id: DiscussionBridgePublicationWork.where(
      bridge_record_id: @record_ids,
    )).delete_all
    DiscussionBridgePublicationWork.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgeSourceSnapshotItem.where(source_snapshot_id: DiscussionBridgeSourceSnapshot.where(
      content_connection_id: @connection_ids,
    )).delete_all
    DiscussionBridgeSourceSnapshot.where(content_connection_id: @connection_ids).delete_all
    DiscussionBridgeSourceRevision.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgeSourceRevocation.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgeContentBinding.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgeSourceAuthor.where(content_connection_id: @connection_ids).delete_all
    DiscussionBridgeAuditEvent.where(connection_id: @connection_public_ids).delete_all
    DiscussionBridgeBridgeRecord.where(id: @record_ids).delete_all
    Post.where(topic_id: @topic_ids).delete_all
    Topic.where(id: @topic_ids).delete_all
    DiscussionBridgeContentConnection.where(id: @connection_ids).delete_all
    @users.reverse_each { |user| user.destroy! if User.exists?(user.id) }
  end
end
