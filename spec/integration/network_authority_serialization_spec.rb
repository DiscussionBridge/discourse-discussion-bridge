# frozen_string_literal: true

require "rails_helper"
require "pg"
require "timeout"

RSpec.describe "R3-F26 network authority serialization" do
  self.use_transactional_tests = false

  before do
    @workers = []
    @site_settings = nil
    @admin = nil
    @category = nil
    @identity = nil
    @connection = nil
    @peer = nil
    @original_forum_name = ENV["DISCUSSIONBRIDGE_FORUM_NAME"]
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "Regional receiver"
    @site_settings = {
      discussion_bridge_enabled: SiteSetting.discussion_bridge_enabled,
      discussion_bridge_endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
      discussion_bridge_service_username: SiteSetting.discussion_bridge_service_username,
      discussion_bridge_effective_category_id: SiteSetting.discussion_bridge_effective_category_id,
      discussion_bridge_effective_tags: SiteSetting.discussion_bridge_effective_tags,
      discussion_bridge_lane_policies: SiteSetting.discussion_bridge_lane_policies,
    }
    @example_token = SecureRandom.hex(6)
    @admin = Fabricate(
      :admin,
      username: "r3f26#{@example_token}",
      email: "r3f26#{@example_token}@example.com",
    )
    @category = Fabricate(:category, name: "R3-F26 #{@example_token}", user: @admin)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = @admin.username
    SiteSetting.discussion_bridge_effective_category_id = @category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @identity = DiscussionBridgeForumIdentity.enable!(actor: @admin)
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "R3-F26 receiver #{@example_token}",
      platform: "discourse",
      allowed_origins: ["https://national.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: [],
      default_category_id: @category.id,
      destination_policies: [destination_policy],
      policy_revision: receiver_policy_revision,
      network_enabled: true,
      network_peer_forum_id: remote_forum_id,
      network_relationship: relationship,
    )
    @peer = DiscussionBridgeNetworkPeer.create!(
      content_connection: @connection,
      name: "National sender #{@example_token}",
      remote_forum_id: remote_forum_id,
      remote_forum_name: "National Organization",
      remote_origin: "https://national.example",
      remote_connection_id: "dbc_#{SecureRandom.hex(12)}",
      remote_secret: "s" * 32,
      relationship: relationship,
      enabled: true,
      authorized_by: @admin,
      authorized_at: Time.zone.now,
    )
  end

  after do
    @workers.each do |worker|
      worker.kill if worker.alive?
      worker.join(5)
    end
    raise "R3-F26 worker survived example cleanup" if @workers.any?(&:alive?)

    cleanup_created_rows
    @site_settings&.each { |name, value| SiteSetting.public_send("#{name}=", value) }
    @original_forum_name.nil? ? ENV.delete("DISCUSSIONBRIDGE_FORUM_NAME") :
      ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = @original_forum_name
  end

  it "commits an admitted receive before a peer disable can invalidate authority" do
    receiver_holds_authority = Queue.new
    continue_receiver = Queue.new
    receiver_result = Queue.new
    disable_pid = Queue.new
    disable_result = Queue.new
    allow(DiscussionBridge::NetworkReplayRegistry).to receive(:reserve!).and_wrap_original do |original, **args|
      receiver_holds_authority << true
      continue_receiver.pop
      original.call(**args)
    end
    ActiveRecord::Base.connection_pool.release_connection

    receiver = start_worker(receiver_result) { receive_source }
    wait_for(receiver_holds_authority)
    disable = start_worker(disable_result) do
      disable_pid << database_pid
      DiscussionBridgeNetworkPeer.disable_authority!(id: @peer.id, actor: @admin)
    end
    wait_for_database_lock(wait_for(disable_pid))
    continue_receiver << true
    wait_for(receiver)
    wait_for(disable)

    expect(receiver_result.pop.fetch("outcome")).to eq("created")
    expect(disable_result.pop).to be_a(DiscussionBridgeNetworkPeer)
    expect(@peer.reload.enabled).to eq(false)
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse").count).to eq(1)
    expect(DiscussionBridgeNetworkReplay.count).to eq(1)
  ensure
    continue_receiver << true if receiver&.alive?
  end

  it "makes a receive waiting behind peer invalidation observe the committed disable" do
    invalidation_holds_authority = Queue.new
    continue_invalidation = Queue.new
    invalidation_result = Queue.new
    receiver_pid = Queue.new
    receiver_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    invalidation = start_worker(invalidation_result) do
      DiscussionBridgeNetworkPeer.transaction do
        DiscussionBridgeForumIdentity.lock.find_by!(
          singleton_key: DiscussionBridgeForumIdentity::SINGLETON_KEY,
        )
        peer = DiscussionBridgeNetworkPeer.lock.find(@peer.id)
        invalidation_holds_authority << true
        continue_invalidation.pop
        peer.update!(enabled: false, disabled_at: Time.zone.now, authorized_by: @admin)
      end
      true
    end
    wait_for(invalidation_holds_authority)
    receiver = start_worker(receiver_result) do
      receiver_pid << database_pid
      receive_source
    end
    wait_for_database_lock(wait_for(receiver_pid))
    continue_invalidation << true
    wait_for(invalidation)
    wait_for(receiver)

    expect(invalidation_result.pop).to eq(true)
    error = receiver_result.pop
    expect(error).to be_a(DiscussionBridge::AdapterRequestBoundary::Error)
    expect(error.error_code).to eq("scope_denied")
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
    expect(DiscussionBridgeNetworkReplay.count).to eq(0)
  ensure
    continue_invalidation << true if invalidation&.alive?
  end

  it "commits an admitted receive before forum rotation disables its route" do
    receiver_holds_authority = Queue.new
    continue_receiver = Queue.new
    receiver_result = Queue.new
    rotation_pid = Queue.new
    rotation_result = Queue.new
    allow(DiscussionBridge::NetworkReplayRegistry).to receive(:reserve!).and_wrap_original do |original, **args|
      receiver_holds_authority << true
      continue_receiver.pop
      original.call(**args)
    end
    ActiveRecord::Base.connection_pool.release_connection

    receiver = start_worker(receiver_result) { receive_source }
    wait_for(receiver_holds_authority)
    rotation = start_worker(rotation_result) do
      rotation_pid << database_pid
      DiscussionBridgeForumIdentity.find(@identity.id).rotate!(actor: @admin)
    end
    wait_for_database_lock(wait_for(rotation_pid))
    continue_receiver << true
    wait_for(receiver)
    wait_for(rotation)

    expect(receiver_result.pop.fetch("outcome")).to eq("created")
    expect(rotation_result.pop).to be_a(DiscussionBridgeForumIdentity)
    expect(@identity.reload.enabled).to eq(false)
    expect(@peer.reload.enabled).to eq(false)
    expect(@connection.reload.network_enabled).to eq(false)
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse").count).to eq(1)
  ensure
    continue_receiver << true if receiver&.alive?
  end

  private

  def receive_source
    DiscussionBridge::NetworkReceiver.call(
      peer: DiscussionBridgeNetworkPeer.find(@peer.id),
      source_detail: source_detail,
      policy_revision: source_policy_revision,
    )
  end

  def destination_policy
    DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
      peer_forum_id: remote_forum_id,
      relationship: relationship,
    )
  end

  def receiver_policy_revision
    DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
      peer_forum_id: remote_forum_id,
      relationship: relationship,
    )
  end

  def source_policy_revision
    DiscussionBridge::DiscourseNetworkProtocol.expected_source_policy_revision(
      local_forum_id: @identity.forum_id,
      relationship: relationship,
    )
  end

  def source_detail
    detail = JSON.parse(
      File.read(
        Rails.root.join(
          "plugins/discourse-discussion-bridge/spec/fixtures/network-source-detail.json",
        ),
      ),
    )
    provenance = detail.fetch("network_provenance")
    operation_id = "dbo_#{SecureRandom.hex(16)}"
    provenance["operation_id"] = operation_id
    detail["correlation_id"] = "r3f26-#{operation_id}"
    detail
  end

  def remote_forum_id
    "dbf_#{"1" * 32}"
  end

  def relationship
    "hub_to_spoke"
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
    Timeout.timeout(30) { target.is_a?(Thread) ? target.join : target.pop }
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
    connection_id = @connection&.id
    peer_id = @peer&.id
    record_ids = if connection_id
      DiscussionBridgeContentBinding.where(content_connection_id: connection_id).pluck(:bridge_record_id)
    else
      []
    end
    topic_ids = DiscussionBridgeBridgeRecord.where(id: record_ids).pluck(:topic_id).compact
    DiscussionBridgeNetworkReplay.where(network_peer_id: peer_id).delete_all if peer_id
    DiscussionBridgeContentBinding.where(bridge_record_id: record_ids).delete_all
    DiscussionBridgeBridgeRecord.where(id: record_ids).delete_all
    Post.where(topic_id: topic_ids).delete_all
    Topic.where(id: topic_ids).delete_all
    DiscussionBridgeAuditEvent.where(connection_id: @connection.public_id).delete_all if @connection
    DiscussionBridgeNetworkPeer.where(id: peer_id).delete_all if peer_id
    DiscussionBridgeContentConnection.where(id: connection_id).delete_all if connection_id
    DiscussionBridgeForumIdentity.where(id: @identity.id).delete_all if @identity
    Category.where(id: @category.id).delete_all if @category
    if @admin
      UserEmail.where(user_id: @admin.id).delete_all
      User.where(id: @admin.id).delete_all
    end
  end
end
