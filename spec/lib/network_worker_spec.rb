# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::NetworkWorker do
  class FakeNetworkPeerClient
    attr_reader :acknowledgements, :failures

    def initialize(work:, detail:)
      @work = work
      @detail = detail
      @acknowledgements = []
      @failures = []
    end

    def start_work_cycle!
    end

    def ensure_work_cycle_active!
      true
    end

    def finish_work_cycle!
    end

    def claim(correlation_id:)
      @claim_correlation_id = correlation_id
      @work ? [@work] : []
    end

    def bridge_record(resource_id, correlation_id:)
      raise "wrong resource" unless resource_id == @work.fetch("resource_id")

      {
        "resource_id" => @work.fetch("resource_id"),
        "topic_id" => @detail.fetch("topic_id"),
        "source_revision" => @work.fetch("source_revision"),
        "source_revision_sequence" => @work.fetch("source_revision_sequence"),
        "bindings" => [
          {
            "binding_id" => "dbb_#{"4" * 32}",
            "connection_id" => @work.fetch("connection_id"),
            "role" => "presentation",
            "state" => "active",
            "external_id" => "national-page-42",
            "canonical_url" => "https://national.example/articles/network-source",
          },
        ],
        "correlation_id" => correlation_id,
      }
    end

    def source_detail(topic_id:, source_revision:, correlation_id:)
      raise "wrong topic" unless topic_id == @detail.fetch("topic_id")
      raise "wrong revision" unless source_revision == @detail.fetch("source_revision")

      [@detail.merge("correlation_id" => correlation_id), nil]
    end

    def acknowledge(work:, destination_binding:, correlation_id:)
      @acknowledgements << {
        work: work,
        destination_binding: destination_binding,
        correlation_id: correlation_id,
      }
      { "terminal" => true }
    end

    def fail(work:, error_code:, correlation_id:)
      @failures << { work: work, error_code: error_code, correlation_id: correlation_id }
      { "terminal" => true }
    end
  end

  class RegistryBackedNetworkPeerClient
    attr_reader :last_acknowledgement_payload, :last_detail, :last_work

    def initialize(connection:)
      @connection = connection
    end

    def start_work_cycle!
    end

    def ensure_work_cycle_active!
      true
    end

    def finish_work_cycle!
    end

    def claim(correlation_id:)
      @last_work = DiscussionBridge::PublicationWorkRegistry.claim(
        connection: @connection,
        worker_id: "discourse-network:composition",
        maximum_items: 1,
        requested_lease_seconds: DiscussionBridge::PublicationWorkProtocol::DEFAULT_LEASE_SECONDS,
        correlation_id: correlation_id,
      ).first&.deep_stringify_keys
      @last_work ? [@last_work] : []
    end

    def bridge_record(resource_id, correlation_id:)
      record = source_record(resource_id)
      binding = record.content_bindings.find_by!(
        content_connection_id: @connection.id,
        role: "presentation",
        state: "active",
      )
      {
        "resource_id" => record.resource_id,
        "topic_id" => record.topic_id,
        "source_revision" => record.source_revision,
        "source_revision_sequence" => record.source_revision_sequence,
        "bindings" => [
          {
            "binding_id" => binding.binding_id,
            "connection_id" => @connection.public_id,
            "role" => binding.role,
            "state" => binding.state,
            "external_id" => binding.external_id,
            "canonical_url" => binding.canonical_url,
          },
        ],
        "correlation_id" => correlation_id,
      }
    end

    def source_detail(topic_id:, source_revision:, correlation_id:)
      record = DiscussionBridgeBridgeRecord.joins(:content_bindings).find_by!(
        topic_id: topic_id,
        discussion_bridge_content_bindings: {
          content_connection_id: @connection.id,
          role: "presentation",
          state: "active",
        },
      )
      revision = record.source_revisions.find_by!(source_revision: source_revision)
      @last_detail = {
        "resource_id" => revision.bridge_record.resource_id,
        "topic_id" => revision.bridge_record.topic_id,
        "topic_url" => revision.topic_url,
        "title" => revision.title,
        "source_revision" => revision.source_revision,
        "source_revision_sequence" => revision.source_revision_sequence,
        "source_created_at" => revision.source_created_at.iso8601(6),
        "source_updated_at" => revision.source_updated_at.iso8601(6),
        "source_authors" => revision.source_authors,
        "categories" => revision.categories,
        "tags" => revision.tags,
        "presentation_mode" => revision.presentation_mode,
        "content_transport" => {
          "mode" => "inline",
          "media_type" => DiscussionBridge::SourcePublicationProtocol::MEDIA_TYPE,
          "byte_length" => revision.byte_length,
          "sha256" => revision.content_sha256,
          "content_html" => revision.content_html,
        },
        "content_disposition" => "complete",
        "network_provenance" => revision.network_provenance,
        "correlation_id" => correlation_id,
      }
      [@last_detail, nil]
    end

    def acknowledge(work:, destination_binding:, correlation_id:)
      @last_acknowledgement_payload = {
        "lease_token" => work.fetch("lease_token"),
        "resource_id" => work.fetch("resource_id"),
        "source_revision" => work.fetch("source_revision"),
        "source_revision_sequence" => work.fetch("source_revision_sequence"),
        "policy_revision" => work.fetch("policy_revision"),
        "destination_policy_id" => work.fetch("destination_policy_id"),
        "action" => work.fetch("action"),
        "stage" => "synchronized",
        "stage_token" => work.fetch("stage_token"),
        "destination_binding" => destination_binding.deep_stringify_keys,
        "synchronized_at" => Time.zone.now.iso8601(6),
        "deployment_state" => "not_required",
        "verification_state" => "not_required",
        "correlation_id" => correlation_id,
      }
      DiscussionBridge::PublicationWorkRegistry.acknowledge(
        connection: @connection,
        work_id: work.fetch("work_id"),
        payload: @last_acknowledgement_payload,
      )
    end

    def replay_last_acknowledgement
      DiscussionBridge::PublicationWorkRegistry.acknowledge(
        connection: @connection,
        work_id: @last_work.fetch("work_id"),
        payload: @last_acknowledgement_payload,
      )
    end

    def fail(work:, error_code:, correlation_id:)
      DiscussionBridge::PublicationWorkRegistry.fail(
        connection: @connection,
        work_id: work.fetch("work_id"),
        payload: {
          "lease_token" => work.fetch("lease_token"),
          "error_code" => error_code,
          "error_detail" => "Bounded composition failure.",
          "failed_at" => Time.zone.now.iso8601(6),
          "correlation_id" => correlation_id,
        },
      )
    end

    private

    def source_record(resource_id)
      DiscussionBridgeBridgeRecord.joins(:content_bindings).find_by!(
        resource_id: resource_id,
        discussion_bridge_content_bindings: {
          content_connection_id: @connection.id,
          role: "presentation",
          state: "active",
        },
      )
    end
  end

  class LostCommittedAcknowledgementResponseClient < RegistryBackedNetworkPeerClient
    def acknowledge(...)
      super
      raise DiscussionBridge::NetworkPeerClient::Error, "transport_timeout"
    end
  end

  class LostUncommittedAcknowledgementResponseClient < RegistryBackedNetworkPeerClient
    def acknowledge(...)
      raise DiscussionBridge::NetworkPeerClient::Error, "transport_timeout"
    end
  end

  class NetworkWorkerResponse
    attr_reader :code

    def initialize(
      payload:,
      correlation_header: payload["correlation_id"],
      code: 200,
      before_chunk: nil
    )
      @code = code.to_s
      @body = JSON.generate(payload)
      @correlation_header = correlation_header
      @before_chunk = before_chunk
    end

    def [](name)
      case name.downcase
      when "content-type"
        "application/json"
      when DiscussionBridge::AdapterRequestBoundary::CORRELATION_HEADER.downcase
        @correlation_header
      end
    end

    def read_body
      @before_chunk&.call
      yield @body
    end
  end

  class NetworkWorkerHTTP
    attr_reader :requests
    attr_accessor :read_timeout, :write_timeout

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(request)
      @requests << request
      yield @responses.fetch(@requests.length - 1)
    end
  end

  class ExpiringAfterRecordClient < DiscussionBridge::NetworkPeerClient
    def initialize(peer, test_clock:)
      @test_clock = test_clock
      super(peer, monotonic_clock: test_clock)
    end

    def bridge_record(...)
      super.tap do
        @test_clock.advance(DiscussionBridge::NetworkPeerClient::WORK_CYCLE_TIMEOUT_SECONDS)
      end
    end
  end

  class ExpiringAfterSourceDetailClient < DiscussionBridge::NetworkPeerClient
    def initialize(peer, test_clock:)
      @test_clock = test_clock
      super(peer, monotonic_clock: test_clock)
    end

    def source_detail(...)
      super.tap do
        @test_clock.advance(DiscussionBridge::NetworkPeerClient::WORK_CYCLE_TIMEOUT_SECONDS)
      end
    end
  end

  class WorkerMonotonicClock
    def initialize(now = 0.0)
      @now = now
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @original_forum_name = ENV["DISCUSSIONBRIDGE_FORUM_NAME"]
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "Regional Chapter"
    DiscussionBridgeForumIdentity.enable!(actor: admin)
    @identity = DiscussionBridgeForumIdentity.current
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "National network source",
      platform: "discourse",
      allowed_origins: ["https://national.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: [],
      default_category_id: category.id,
      destination_policies: [destination_policy],
      policy_revision: receiver_policy_revision,
      network_enabled: true,
      network_peer_forum_id: remote_forum_id,
      network_relationship: network_relationship,
    )
    @peer = DiscussionBridgeNetworkPeer.create!(
      content_connection: @connection,
      name: "National Organization",
      remote_forum_id: remote_forum_id,
      remote_forum_name: "National Organization",
      remote_origin: "https://national.example",
      remote_connection_id: "dbc_#{"1" * 24}",
      remote_secret: "s" * 32,
      relationship: network_relationship,
      enabled: true,
      authorized_by: admin,
      authorized_at: Time.zone.now,
    )
  end

  after { ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = @original_forum_name }

  def destination_policy
    DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
      peer_forum_id: remote_forum_id,
      relationship: network_relationship,
    )
  end

  def receiver_policy_revision
    DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
      peer_forum_id: remote_forum_id,
      relationship: network_relationship,
    )
  end

  def remote_forum_id
    "dbf_11111111111111111111111111111111"
  end

  def network_relationship
    "hub_to_spoke"
  end

  def source_detail
    JSON.parse(
      File.read(
        File.expand_path("../fixtures/network-source-detail.json", __dir__),
      ),
    )
  end

  def work(action: "publish", detail: source_detail, policy_revision: source_policy_revision)
    {
      "work_id" => "dbw_#{"1" * 32}",
      "connection_id" => @peer.remote_connection_id,
      "resource_id" => source_detail.fetch("resource_id"),
      "action" => action,
      "source_revision" => detail.fetch("source_revision"),
      "source_revision_sequence" => detail.fetch("source_revision_sequence"),
      "policy_revision" => policy_revision,
      "destination_policy_id" => source_destination_policy.fetch("destination_policy_id"),
      "lease_token" => "2" * 64,
      "stage_token" => "3" * 64,
      "lease_expires_at" => 5.minutes.from_now.iso8601(6),
    }
  end

  def source_policy_revision
    DiscussionBridge::DiscourseNetworkProtocol.expected_source_policy_revision(
      local_forum_id: @identity.forum_id,
      relationship: @peer.relationship,
    )
  end

  def source_destination_policy
    DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
      peer_forum_id: @identity.forum_id,
      relationship: @peer.relationship,
    )
  end

  def network_correlation(stage)
    "network-#{stage}-#{"a" * 16}"
  end

  def build_registry_backed_client(client_class)
    receiver_forum_id = @identity.forum_id
    source_forum_id = @peer.remote_forum_id
    source_policy = DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
      peer_forum_id: receiver_forum_id,
      relationship: network_relationship,
    )
    source_policy_revision_value = DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
      peer_forum_id: receiver_forum_id,
      relationship: network_relationship,
    )
    Discourse.stubs(:base_url).returns("https://national.example")
    @identity.update_columns(forum_id: source_forum_id, site_origin: "https://national.example")
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "National Organization"
    source_connection, source_secret = DiscussionBridgeContentConnection.issue!(
      name: "Regional chapter destination",
      platform: "discourse",
      allowed_origins: ["https://national.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
      destination_policies: [source_policy],
      policy_revision: source_policy_revision_value,
      network_enabled: true,
      network_peer_forum_id: receiver_forum_id,
      network_relationship: network_relationship,
    )
    source_topic = Fabricate(:topic, user: admin, category: category, title: "National acknowledgement loss")
    source_post = Fabricate(:post, topic: source_topic, user: admin, post_number: 1, raw: "National body")
    source_post.update_columns(cooked: "<p>National body.</p>")
    source_record = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: source_connection.id,
      topic_id: source_topic.id,
      external_id: "national-acknowledgement-loss",
      canonical_url: "https://national.example/published/national-acknowledgement-loss",
      native_materialization: true,
    ).record
    DiscussionBridge::SourceRevisionMaterializer.call(
      record: source_record,
      connection: source_connection,
    )
    source_topic.update_columns(deleted_at: Time.zone.now)

    Discourse.stubs(:base_url).returns("https://regional.example")
    @identity.update_columns(forum_id: receiver_forum_id, site_origin: "https://regional.example")
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "Regional Chapter"
    @peer.update!(remote_connection_id: source_connection.public_id, remote_secret: source_secret)
    [client_class.new(connection: source_connection), source_connection]
  end

  def use_network_http(*responses)
    http = NetworkWorkerHTTP.new(responses)
    FinalDestination::HTTP.stubs(:start).yields(http)
    SecureRandom.stubs(:hex).with(8).returns("a" * 16)
    SecureRandom.stubs(:hex).with(12).returns("d" * 24)
    SecureRandom.stubs(:hex).with(16).returns("c" * 32)
    SecureRandom.stubs(:hex).with(32).returns("b" * 64)
    http
  end

  def claim_response(header: network_correlation("claim"), work_item: work, before_chunk: nil)
    correlation = network_correlation("claim")
    NetworkWorkerResponse.new(
      correlation_header: header,
      payload: {
        "publication_work" => [work_item],
        "claimed_at" => Time.zone.now.iso8601(6),
        "correlation_id" => correlation,
      },
      before_chunk: before_chunk,
    )
  end

  def record_response(
    header: network_correlation("record"),
    work_item: work,
    detail: source_detail,
    before_chunk: nil
  )
    correlation = network_correlation("record")
    NetworkWorkerResponse.new(
      correlation_header: header,
      payload: {
        "bridge_record" => {
          "resource_id" => work_item.fetch("resource_id"),
          "topic_id" => detail.fetch("topic_id"),
          "source_revision" => work_item.fetch("source_revision"),
          "source_revision_sequence" => work_item.fetch("source_revision_sequence"),
          "bindings" => [
            {
              "binding_id" => "dbb_#{"4" * 32}",
              "connection_id" => work_item.fetch("connection_id"),
              "role" => "presentation",
              "state" => "active",
              "external_id" => "national-page-42",
              "canonical_url" => "https://national.example/articles/network-source",
            },
          ],
        },
        "correlation_id" => correlation,
      },
      before_chunk: before_chunk,
    )
  end

  def detail_response(header: network_correlation("source"), detail: source_detail, before_chunk: nil)
    correlation = network_correlation("source")
    NetworkWorkerResponse.new(
      correlation_header: header,
      payload: detail.merge("correlation_id" => correlation),
      before_chunk: before_chunk,
    )
  end

  def acknowledgement_response(header: network_correlation("ack"), before_chunk: nil)
    correlation = network_correlation("ack")
    NetworkWorkerResponse.new(
      correlation_header: header,
      payload: {
        "work_id" => work.fetch("work_id"),
        "accepted_stage" => "synchronized",
        "resulting_state" => "acknowledged",
        "terminal" => true,
        "correlation_id" => correlation,
      },
      before_chunk: before_chunk,
    )
  end

  def failure_response(header: network_correlation("failure"), before_chunk: nil)
    correlation = network_correlation("failure")
    NetworkWorkerResponse.new(
      correlation_header: header,
      payload: {
        "resulting_state" => "operator_attention",
        "terminal" => true,
        "correlation_id" => correlation,
      },
      before_chunk: before_chunk,
    )
  end

  it "claims one item, materializes it once, and acknowledges the stable local binding" do
    expect(source_policy_revision).not_to eq(receiver_policy_revision)
    client = FakeNetworkPeerClient.new(work: work, detail: source_detail)
    result = described_class.call(@peer, client: client)

    expect(result).to include(outcome: "acknowledged")
    expect(client.failures).to be_empty
    acknowledgement = client.acknowledgements.sole
    expect(acknowledgement.dig(:work, "policy_revision")).to eq(source_policy_revision)
    expect(acknowledgement.dig(:work, "policy_revision")).not_to eq(@connection.policy_revision)
    expect(acknowledgement.fetch(:destination_binding)).to include(
      binding_id: "dbb_#{"4" * 32}",
      content_disposition: "complete",
      external_id: "national-page-42",
      canonical_url: "https://national.example/articles/network-source",
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse").count).to eq(1)
  end

  it "updates the same publication under the immutable source policy and acknowledges it unchanged" do
    initial = FakeNetworkPeerClient.new(work: work, detail: source_detail)
    expect(described_class.call(@peer, client: initial)[:outcome]).to eq("acknowledged")
    record = DiscussionBridgeBridgeRecord.last
    topic_id = record.topic_id

    revised = source_detail
    body = "<p>Updated national program.</p>"
    revised["source_revision"] = "post:501:version:3"
    revised["source_revision_sequence"] = 3
    revised["source_updated_at"] = "2026-09-29T19:00:00Z"
    revised["content_transport"].merge!(
      "byte_length" => body.bytesize,
      "sha256" => Digest::SHA256.hexdigest(body),
      "content_html" => body,
    )
    revised["network_provenance"]["operation_id"] = "dbo_#{"3" * 32}"
    update_client = FakeNetworkPeerClient.new(
      work: work(action: "update", detail: revised),
      detail: revised,
    )

    expect(described_class.call(@peer, client: update_client)[:outcome]).to eq("acknowledged")
    expect(record.reload.topic_id).to eq(topic_id)
    expect(record.topic.first_post.raw).to include("Updated national program")
    expect(update_client.acknowledgements.sole.dig(:work, "policy_revision")).to eq(
      source_policy_revision,
    )
  end

  it "persists a real source-issued reciprocal publish through restore chain and exact acknowledgements" do
    receiver_forum_id = @identity.forum_id
    source_forum_id = @peer.remote_forum_id
    source_policy = DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
      peer_forum_id: receiver_forum_id,
      relationship: network_relationship,
    )
    source_policy_revision_value = DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
      peer_forum_id: receiver_forum_id,
      relationship: network_relationship,
    )
    activate_forum = lambda do |forum_id, origin, name|
      Discourse.stubs(:base_url).returns(origin)
      @identity.update_columns(forum_id: forum_id, site_origin: origin)
      ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = name
    end
    activate_forum.call(source_forum_id, "https://national.example", "National Organization")
    source_connection, source_secret = DiscussionBridgeContentConnection.issue!(
      name: "Regional chapter destination",
      platform: "discourse",
      allowed_origins: ["https://national.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
      destination_policies: [source_policy],
      policy_revision: source_policy_revision_value,
      network_enabled: true,
      network_peer_forum_id: receiver_forum_id,
      network_relationship: network_relationship,
    )
    source_topic = Fabricate(:topic, user: admin, category: category, title: "National composition")
    source_post = Fabricate(:post, topic: source_topic, user: admin, post_number: 1, raw: "National body")
    source_post.update_columns(cooked: "<p>National body.</p>")
    source_record = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: source_connection.id,
      topic_id: source_topic.id,
      external_id: "national-composition",
      canonical_url: "https://national.example/published/national-composition",
      native_materialization: true,
    ).record
    DiscussionBridge::SourceRevisionMaterializer.call(
      record: source_record,
      connection: source_connection,
    )
    source_topic.update_columns(deleted_at: Time.zone.now)

    activate_forum.call(receiver_forum_id, "https://regional.example", "Regional Chapter")
    @peer.update!(remote_connection_id: source_connection.public_id, remote_secret: source_secret)
    client = RegistryBackedNetworkPeerClient.new(connection: source_connection)
    published = described_class.call(@peer, client: client)
    expect(published).to include(outcome: "acknowledged")
    expect(client.last_work).to include(
      "policy_revision" => source_policy_revision_value,
      "destination_policy_id" => source_policy.fetch("destination_policy_id"),
    )
    expect(source_connection.publication_works.find_by!(work_id: client.last_work.fetch("work_id"))).to(
      have_attributes(state: "acknowledged"),
    )
    receiver_record = DiscussionBridgeBridgeRecord.find_by!(resource_id: published.dig(:result, "resource_id"))
    receiver_topic = receiver_record.topic
    first_post_id = receiver_topic.first_post.id
    reply = Fabricate(:post, topic: receiver_topic, user: admin, post_number: 2, raw: "Local reply")
    replay = DiscussionBridge::NetworkReceiver.call(
      peer: @peer,
      source_detail: client.last_detail,
      policy_revision: client.last_work.fetch("policy_revision"),
      action: client.last_work.fetch("action"),
    )
    expect(replay.fetch("mutated")).to eq(false)
    expect(client.replay_last_acknowledgement).to include(terminal: true)
    expect(DiscussionBridgeNetworkReplay.last.immutable_operation.fetch("policy_revision")).to eq(
      source_policy_revision_value,
    )

    activate_forum.call(source_forum_id, "https://national.example", "National Organization")
    source_topic.update_columns(deleted_at: nil)
    source_post.update_columns(cooked: "<p>National body updated.</p>", updated_at: 1.minute.from_now)
    DiscussionBridge::SourcePublicationLifecycle.reconcile_topic!(source_topic.id)
    source_topic.update_columns(deleted_at: Time.zone.now)
    activate_forum.call(receiver_forum_id, "https://regional.example", "Regional Chapter")
    updated = described_class.call(@peer, client: client)
    expect(updated).to include(outcome: "acknowledged")
    expect(client.last_work.fetch("action")).to eq("update")
    expect(receiver_record.reload.topic_id).to eq(receiver_topic.id)
    expect(receiver_topic.first_post.reload.id).to eq(first_post_id)
    expect(receiver_topic.first_post.raw).to include("National body updated")
    expect(receiver_topic.posts.find(reply.id).raw).to eq("Local reply")

    activate_forum.call(source_forum_id, "https://national.example", "National Organization")
    source_topic.update_columns(deleted_at: nil)
    source_topic.update!(visible: false)
    DiscussionBridge::SourceRevocationRegistry.reconcile_record!(
      record: source_record,
      connection: source_connection,
    )
    source_topic.update_columns(deleted_at: Time.zone.now)
    activate_forum.call(receiver_forum_id, "https://regional.example", "Regional Chapter")
    withdrawn = described_class.call(@peer, client: client)
    expect(withdrawn).to include(outcome: "acknowledged")
    expect(client.last_work.fetch("action")).to eq("unpublish")
    expect(receiver_record.reload.network_provenance.fetch("local_passive_policy_revision")).to eq(
      source_policy_revision_value,
    )
    expect(receiver_topic.reload).to have_attributes(closed: true, visible: false)

    activate_forum.call(source_forum_id, "https://national.example", "National Organization")
    source_topic.update_columns(deleted_at: nil)
    source_topic.update!(visible: true)
    DiscussionBridge::SourceRevocationRegistry.reconcile_record!(
      record: source_record,
      connection: source_connection,
    )
    source_topic.update_columns(deleted_at: Time.zone.now)
    activate_forum.call(receiver_forum_id, "https://regional.example", "Regional Chapter")
    restored = described_class.call(@peer, client: client)
    expect(restored).to include(outcome: "acknowledged")
    expect(client.last_work.fetch("action")).to eq("restore")
    expect(receiver_record.reload.topic_id).to eq(receiver_topic.id)
    expect(receiver_topic.reload).to have_attributes(closed: false, visible: true)
    expect(receiver_topic.first_post.id).to eq(first_post_id)
    expect(receiver_topic.posts.find(reply.id).raw).to eq("Local reply")
    restored_replay = DiscussionBridge::NetworkReceiver.call(
      peer: @peer,
      source_detail: client.last_detail,
      policy_revision: client.last_work.fetch("policy_revision"),
      action: client.last_work.fetch("action"),
    )
    expect(restored_replay.fetch("mutated")).to eq(false)
    expect(client.replay_last_acknowledgement).to include(terminal: true)
  end

  it "reports a bounded terminal failure instead of acknowledging invalid provenance" do
    invalid = source_detail
    invalid["network_provenance"]["relationship"] = "spoke_to_hub"
    client = FakeNetworkPeerClient.new(work: work, detail: invalid)

    result = described_class.call(@peer, client: client)

    expect(result).to include(outcome: "failed", error_code: "scope_denied")
    expect(client.acknowledgements).to be_empty
    expect(client.failures.sole.fetch(:error_code)).to eq("scope_denied")
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
  end

  it "rejects each mismatched source-work authority field before destination mutation" do
    mismatches = {
      "connection_id" => "dbc_#{"9" * 24}",
      "policy_revision" => DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
        peer_forum_id: "dbf_#{"9" * 32}",
        relationship: network_relationship,
      ),
      "destination_policy_id" => DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
        peer_forum_id: "dbf_#{"9" * 32}",
        relationship: network_relationship,
      ).fetch("destination_policy_id"),
    }

    mismatches.each do |field, value|
      client = FakeNetworkPeerClient.new(work: work.merge(field => value), detail: source_detail)

      expect(described_class.call(@peer, client: client)).to include(
        outcome: "failed",
        error_code: "scope_denied",
      )
      expect(client.acknowledgements).to be_empty
      expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
    end
  end

  it "is idle without work and performs no destination mutation" do
    client = FakeNetworkPeerClient.new(work: nil, detail: source_detail)

    expect(described_class.call(@peer, client: client)).to eq(outcome: "idle")
    expect(client.acknowledgements).to be_empty
    expect(client.failures).to be_empty
  end

  it "stops after an invalid claim response without reporting unaccepted work" do
    http = use_network_http(claim_response(header: "different-request"))
    DiscussionBridge::NetworkReceiver.expects(:call).never

    result = described_class.call(@peer)

    expect(result).to eq(outcome: "failed", error_code: "validation_failed")
    expect(http.requests.map(&:path)).to eq([
      "/discussion-bridge/v1/publication-work/claim.json",
    ])
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
  end

  it "rejects an invalid record response before destination mutation and reports the accepted work" do
    http = use_network_http(
      claim_response,
      record_response(header: "different-request"),
      failure_response,
    )
    DiscussionBridge::NetworkReceiver.expects(:call).never

    result = described_class.call(@peer)

    expect(result).to eq(outcome: "failed", error_code: "validation_failed")
    expect(http.requests.map(&:path)).to eq([
      "/discussion-bridge/v1/publication-work/claim.json",
      "/discussion-bridge/v1/bridge-records/#{work.fetch("resource_id")}.json",
      "/discussion-bridge/v1/publication-work/#{work.fetch("work_id")}/failure.json",
    ])
    expect(JSON.parse(http.requests.last.body)).to include("error_code" => "validation_failed")
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
  end

  it "rejects an invalid source response before destination or replay mutation" do
    http = use_network_http(
      claim_response,
      record_response,
      detail_response(header: "different-request"),
      failure_response,
    )
    DiscussionBridge::NetworkReceiver.expects(:call).never

    result = described_class.call(@peer)

    expect(result).to eq(outcome: "failed", error_code: "validation_failed")
    expect(http.requests.map(&:path)).to include(
      "/discussion-bridge/v1/source-topics/#{source_detail.fetch("topic_id")}.json?" \
        "source_revision=#{CGI.escape(work.fetch("source_revision"))}",
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
    expect(DiscussionBridgeNetworkReplay.count).to eq(0)
  end

  it "does not report acknowledgement after an invalid acknowledgement response" do
    http = use_network_http(
      claim_response,
      record_response,
      detail_response,
      acknowledgement_response(header: "different-request"),
      failure_response,
    )

    result = described_class.call(@peer)

    expect(result).to eq(outcome: "failed", error_code: "validation_failed")
    expect(http.requests.map(&:path).last(2)).to eq([
      "/discussion-bridge/v1/publication-work/#{work.fetch("work_id")}/acknowledgement.json",
      "/discussion-bridge/v1/publication-work/#{work.fetch("work_id")}/failure.json",
    ])
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse").count).to eq(1)
    expect(DiscussionBridgeNetworkReplay.count).to eq(1)
  end

  it "does not recurse when the failure response correlation is invalid" do
    http = use_network_http(
      claim_response,
      record_response(header: "different-request"),
      failure_response(header: "different-request"),
    )

    result = described_class.call(@peer)

    expect(result).to eq(outcome: "failed", error_code: "validation_failed")
    expect(http.requests.length).to eq(3)
    expect(http.requests.last.path).to eq(
      "/discussion-bridge/v1/publication-work/#{work.fetch("work_id")}/failure.json",
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
  end

  it "rejects missing, malformed, and expired remote leases before record retrieval or mutation" do
    invalid_leases = {
      nil => "malformed_value",
      "not-a-timestamp" => "malformed_value",
      1.minute.ago.iso8601(6) => "work_expired",
    }

    invalid_leases.each do |lease_expires_at, error_code|
      invalid_work = work.merge("lease_expires_at" => lease_expires_at)
      client = FakeNetworkPeerClient.new(work: invalid_work, detail: source_detail)

      expect(described_class.call(@peer, client: client)).to eq(
        outcome: "failed",
        error_code: error_code,
      )
      expect(client.acknowledgements).to be_empty
      expect(client.failures.length).to eq(1)
      expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
    end
  end

  it "does not report unknown work when the claim response exceeds the exchange deadline" do
    clock = WorkerMonotonicClock.new
    http = use_network_http(claim_response(before_chunk: -> { clock.advance(31) }))
    client = DiscussionBridge::NetworkPeerClient.new(@peer, monotonic_clock: clock)
    DiscussionBridge::NetworkReceiver.expects(:call).never

    expect(described_class.call(@peer, client: client)).to eq(
      outcome: "failed",
      error_code: "transport_timeout",
    )
    expect(http.requests.map(&:path)).to eq([
      "/discussion-bridge/v1/publication-work/claim.json",
    ])
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
  end

  it "stops an expired work cycle before active destination mutation" do
    clock = WorkerMonotonicClock.new
    http = use_network_http(claim_response, record_response, failure_response)
    client = ExpiringAfterRecordClient.new(@peer, test_clock: clock)
    DiscussionBridge::NetworkReceiver.expects(:call).never

    expect(described_class.call(@peer, client: client)).to eq(
      outcome: "failed",
      error_code: "transport_timeout",
    )
    expect(http.requests.map(&:path).last).to eq(
      "/discussion-bridge/v1/publication-work/#{work.fetch("work_id")}/failure.json",
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
  end

  it "rechecks the cycle after source retrieval immediately before active mutation" do
    clock = WorkerMonotonicClock.new
    http = use_network_http(claim_response, record_response, detail_response, failure_response)
    client = ExpiringAfterSourceDetailClient.new(@peer, test_clock: clock)
    DiscussionBridge::NetworkReceiver.expects(:call).never

    expect(described_class.call(@peer, client: client)).to eq(
      outcome: "failed",
      error_code: "transport_timeout",
    )
    expect(http.requests.map(&:path).last).to eq(
      "/discussion-bridge/v1/publication-work/#{work.fetch("work_id")}/failure.json",
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
  end

  it "stops an expired work cycle before changing an existing passive publication" do
    initial = FakeNetworkPeerClient.new(work: work, detail: source_detail)
    expect(described_class.call(@peer, client: initial)[:outcome]).to eq("acknowledged")
    record = DiscussionBridgeBridgeRecord.last
    topic = record.topic
    original_provenance = record.network_provenance.deep_dup
    original_topic_state = topic.attributes.slice("closed", "visible")

    passive_work = work(action: "hold")
    remote_record = FakeNetworkPeerClient.new(
      work: passive_work,
      detail: source_detail,
    ).bridge_record(passive_work.fetch("resource_id"), correlation_id: "record-fixture")
    clock = lambda do
      inside_record_lock = caller_locations.any? { |location| location.base_label == "with_lock" }
      inside_record_lock ? DiscussionBridge::NetworkPeerClient::WORK_CYCLE_TIMEOUT_SECONDS : 0.0
    end
    client = DiscussionBridge::NetworkPeerClient.new(@peer, monotonic_clock: clock)
    client.stubs(:claim).returns([passive_work])
    client.stubs(:bridge_record).returns(remote_record)
    client.expects(:acknowledge).never
    client.expects(:fail).once.returns(
      "resulting_state" => "retry_wait",
      "terminal" => false,
    )

    expect(described_class.call(@peer, client: client)).to eq(
      outcome: "failed",
      error_code: "transport_timeout",
    )
    expect(record.reload).to have_attributes(state: "healthy")
    expect(record.network_provenance).to eq(original_provenance)
    expect(topic.reload.attributes.slice("closed", "visible")).to eq(original_topic_state)
  end

  it "retains the committed local identity when the cycle expires after mutation and before acknowledgement" do
    clock = lambda do
      mutated = DiscussionBridgeBridgeRecord.where(direction: "to_discourse").exists?
      mutated ? DiscussionBridge::NetworkPeerClient::WORK_CYCLE_TIMEOUT_SECONDS : 0.0
    end
    http = use_network_http(claim_response, record_response, detail_response, failure_response)
    client = DiscussionBridge::NetworkPeerClient.new(@peer, monotonic_clock: clock)

    expect(described_class.call(@peer, client: client)).to eq(
      outcome: "failed",
      error_code: "transport_timeout",
    )
    expect(http.requests.none? { |request| request.path.include?("acknowledgement") }).to eq(true)
    expect(http.requests.last.path).to end_with("/failure.json")
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse").count).to eq(1)
    expect(DiscussionBridgeNetworkReplay.count).to eq(1)
  end

  it "retains local mutation and reports failure once when the acknowledgement response times out" do
    clock = WorkerMonotonicClock.new
    http = use_network_http(
      claim_response,
      record_response,
      detail_response,
      acknowledgement_response(before_chunk: -> { clock.advance(31) }),
      failure_response,
    )
    client = DiscussionBridge::NetworkPeerClient.new(@peer, monotonic_clock: clock)

    expect(described_class.call(@peer, client: client)).to eq(
      outcome: "failed",
      error_code: "transport_timeout",
    )
    expect(http.requests.map(&:path).last(2)).to eq([
      "/discussion-bridge/v1/publication-work/#{work.fetch("work_id")}/acknowledgement.json",
      "/discussion-bridge/v1/publication-work/#{work.fetch("work_id")}/failure.json",
    ])
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse").count).to eq(1)
    expect(DiscussionBridgeNetworkReplay.count).to eq(1)
  end

  it "preserves an authoritative remote acknowledgement when its response is lost" do
    client, source_connection = build_registry_backed_client(LostCommittedAcknowledgementResponseClient)

    expect(described_class.call(@peer, client: client)).to eq(
      outcome: "failed",
      error_code: "transport_timeout",
    )
    source_work = source_connection.publication_works.find_by!(work_id: client.last_work.fetch("work_id"))
    expect(source_work).to have_attributes(state: "acknowledged")
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse").count).to eq(1)
    expect(DiscussionBridgeNetworkReplay.count).to eq(1)
  end

  it "retains local identity while an uncommitted lost acknowledgement enters source retry" do
    client, source_connection = build_registry_backed_client(LostUncommittedAcknowledgementResponseClient)

    expect(described_class.call(@peer, client: client)).to eq(
      outcome: "failed",
      error_code: "transport_timeout",
    )
    source_work = source_connection.publication_works.find_by!(work_id: client.last_work.fetch("work_id"))
    expect(source_work).to have_attributes(state: "retry_wait", attempt_count: 1)
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse").count).to eq(1)
    expect(DiscussionBridgeNetworkReplay.count).to eq(1)
  end

  it "bounds failure reporting to one attempt without replacing the original error" do
    clock = WorkerMonotonicClock.new
    http = use_network_http(
      claim_response,
      record_response(header: "different-request"),
      failure_response(before_chunk: -> { clock.advance(31) }),
    )
    client = DiscussionBridge::NetworkPeerClient.new(@peer, monotonic_clock: clock)

    expect(described_class.call(@peer, client: client)).to eq(
      outcome: "failed",
      error_code: "validation_failed",
    )
    expect(http.requests.length).to eq(3)
    expect(http.requests.last.path).to eq(
      "/discussion-bridge/v1/publication-work/#{work.fetch("work_id")}/failure.json",
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
  end

  %w[hold unpublish].each do |action|
    it "applies network #{action} before terminal acknowledgement" do
      initial = FakeNetworkPeerClient.new(work: work, detail: source_detail)
      expect(described_class.call(@peer, client: initial)[:outcome]).to eq("acknowledged")
      record = DiscussionBridgeBridgeRecord.last
      expect(record.state).to eq("healthy")

      passive = FakeNetworkPeerClient.new(work: work(action: action), detail: source_detail)
      result = described_class.call(@peer, client: passive)

      expect(result).to include(outcome: "acknowledged")
      expect(result.dig(:result, "mutated")).to be(true)
      expect(passive.acknowledgements.length).to eq(1)
      expect(record.reload.state).to eq("attention")
      expect(record.topic.reload).to have_attributes(closed: true, visible: false)
    end
  end

  it "restores the exact passive network publication and preserves its local identity and replies" do
    initial = FakeNetworkPeerClient.new(work: work, detail: source_detail)
    expect(described_class.call(@peer, client: initial)[:outcome]).to eq("acknowledged")
    record = DiscussionBridgeBridgeRecord.last
    topic = record.topic
    first_post_id = topic.first_post.id
    reply = Fabricate(:post, topic: topic, user: admin, post_number: 2, raw: "Local reply survives restore")

    passive_detail = source_detail.merge(
      "source_revision" => "revocation:c4965d46:3",
      "source_revision_sequence" => 3,
    )
    passive = FakeNetworkPeerClient.new(
      work: work(action: "unpublish", detail: passive_detail),
      detail: passive_detail,
    )
    expect(described_class.call(@peer, client: passive)[:outcome]).to eq("acknowledged")
    expect(record.reload.network_provenance).to include(
      "local_passive_action" => "unpublish",
      "local_passive_source_revision" => passive_detail.fetch("source_revision"),
      "local_passive_source_revision_sequence" => 3,
      "local_passive_predecessor_revision" => source_detail.fetch("source_revision"),
      "local_passive_predecessor_revision_sequence" => 2,
    )

    restore_detail = source_detail.deep_dup
    restore_detail["source_revision"] = "post:501:version:4"
    restore_detail["source_revision_sequence"] = 4
    restore_detail["source_updated_at"] = "2026-09-29T18:30:00Z"
    restore_detail["content_transport"]["content_html"] = "<p>National program restored.</p>"
    restore_detail["content_transport"]["byte_length"] = restore_detail.dig("content_transport", "content_html").bytesize
    restore_detail["content_transport"]["sha256"] = Digest::SHA256.hexdigest(
      restore_detail.dig("content_transport", "content_html"),
    )
    restore_detail["network_provenance"]["operation_id"] = "dbo_44444444444444444444444444444444"
    restore = FakeNetworkPeerClient.new(
      work: work(action: "restore", detail: restore_detail),
      detail: restore_detail,
    )
    restored = described_class.call(@peer, client: restore)
    expect(restored).to include(outcome: "acknowledged")
    expect(restored.dig(:result, "mutated")).to be(true)
    expect(restore.failures).to be_empty
    expect(record.reload).to have_attributes(state: "healthy", topic_id: topic.id)
    expect(topic.reload).to have_attributes(closed: false, visible: true)
    expect(topic.first_post.id).to eq(first_post_id)
    expect(topic.first_post.raw).to include("National program restored")
    expect(topic.posts.find(reply.id).raw).to eq("Local reply survives restore")
    expect(record.network_provenance).not_to have_key("local_passive_action")

    replay = FakeNetworkPeerClient.new(
      work: work(action: "restore", detail: restore_detail),
      detail: restore_detail,
    )
    replayed = described_class.call(@peer, client: replay)
    expect(replayed).to include(outcome: "acknowledged")
    expect(replayed.dig(:result, "mutated")).to be(false)

    second_passive_detail = restore_detail.merge(
      "source_revision" => "revocation:c4965d46:5",
      "source_revision_sequence" => 5,
    )
    second_passive = FakeNetworkPeerClient.new(
      work: work(action: "unpublish", detail: second_passive_detail),
      detail: second_passive_detail,
    )
    expect(described_class.call(@peer, client: second_passive)[:outcome]).to eq("acknowledged")
    @connection.update!(allowed_origins: ["https://withdrawn.example"])
    unauthorized_replay = FakeNetworkPeerClient.new(
      work: work(action: "restore", detail: restore_detail),
      detail: restore_detail,
    )
    expect(described_class.call(@peer, client: unauthorized_replay)).to include(
      outcome: "failed",
      error_code: "scope_denied",
    )
    expect(record.reload.state).to eq("attention")
    expect(topic.reload).to have_attributes(closed: true, visible: false)
  end

  it "rejects restore from unrelated attention or stale source-policy authority" do
    initial = FakeNetworkPeerClient.new(work: work, detail: source_detail)
    expect(described_class.call(@peer, client: initial)[:outcome]).to eq("acknowledged")
    record = DiscussionBridgeBridgeRecord.last
    record.topic.update!(closed: true, visible: false)
    record.update!(state: "attention")

    unrelated = FakeNetworkPeerClient.new(work: work(action: "restore"), detail: source_detail)
    expect(described_class.call(@peer, client: unrelated)).to include(
      outcome: "failed",
      error_code: "reconciliation_required",
    )
    expect(unrelated.acknowledgements).to be_empty

    record.update!(
      network_provenance: record.network_provenance.merge(
        "local_passive_action" => "hold",
        "local_passive_source_revision" => source_detail.fetch("source_revision"),
        "local_passive_policy_revision" => source_policy_revision,
      ),
    )
    stale_policy = DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
      peer_forum_id: "dbf_#{"9" * 32}",
      relationship: network_relationship,
    )
    stale = FakeNetworkPeerClient.new(
      work: work(action: "restore", policy_revision: stale_policy),
      detail: source_detail,
    )
    expect(described_class.call(@peer, client: stale)).to include(
      outcome: "failed",
      error_code: "scope_denied",
    )
    expect(stale.acknowledgements).to be_empty
  end
end
