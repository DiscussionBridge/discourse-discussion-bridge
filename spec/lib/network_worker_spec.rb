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
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "National network source",
      platform: "discourse",
      allowed_origins: ["https://national.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: [],
      default_category_id: category.id,
      destination_policies: [destination_policy],
      policy_revision: "policy:2026-09-27:1",
      network_enabled: true,
      network_peer_forum_id: "dbf_11111111111111111111111111111111",
      network_relationship: "hub_to_spoke",
    )
    @peer = DiscussionBridgeNetworkPeer.create!(
      content_connection: @connection,
      name: "National Organization",
      remote_forum_id: "dbf_11111111111111111111111111111111",
      remote_forum_name: "National Organization",
      remote_origin: "https://national.example",
      remote_connection_id: "dbc_#{"1" * 24}",
      remote_secret: "s" * 32,
      relationship: "hub_to_spoke",
      enabled: true,
      authorized_by: admin,
      authorized_at: Time.zone.now,
    )
  end

  after { ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = @original_forum_name }

  def destination_policy
    {
      "destination_policy_id" => "destination:discourse:network:1",
      "profile" => "discourse_as_publisher",
      "presentation_mode" => "interactive",
      "container_mapping" => {
        "source" => "discourse:category:national",
        "destination" => "discourse:category:network",
      },
      "taxonomy_mapping" => { "mode" => "mapped_only" },
      "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => {
        "maximum_bytes" => 49_152,
        "overflow_behavior" => "excerpt_with_read_more",
      },
      "catalog_revision" => "catalog:discourse:2026-09-27:1",
    }
  end

  def source_detail
    JSON.parse(
      File.read(
        File.expand_path("../fixtures/network-source-detail.json", __dir__),
      ),
    )
  end

  def work(action: "publish", detail: source_detail)
    {
      "work_id" => "dbw_#{"1" * 32}",
      "connection_id" => @peer.remote_connection_id,
      "resource_id" => source_detail.fetch("resource_id"),
      "action" => action,
      "source_revision" => detail.fetch("source_revision"),
      "source_revision_sequence" => detail.fetch("source_revision_sequence"),
      "policy_revision" => "policy:2026-09-27:1",
      "destination_policy_id" => destination_policy.fetch("destination_policy_id"),
      "lease_token" => "2" * 64,
      "stage_token" => "3" * 64,
    }
  end

  it "claims one item, materializes it once, and acknowledges the stable local binding" do
    client = FakeNetworkPeerClient.new(work: work, detail: source_detail)
    result = described_class.call(@peer, client: client)

    expect(result).to include(outcome: "acknowledged")
    expect(client.failures).to be_empty
    acknowledgement = client.acknowledgements.sole
    expect(acknowledgement.fetch(:destination_binding)).to include(
      binding_id: "dbb_#{"4" * 32}",
      content_disposition: "complete",
      external_id: "national-page-42",
      canonical_url: "https://national.example/articles/network-source",
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse").count).to eq(1)
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

  it "is idle without work and performs no destination mutation" do
    client = FakeNetworkPeerClient.new(work: nil, detail: source_detail)

    expect(described_class.call(@peer, client: client)).to eq(outcome: "idle")
    expect(client.acknowledgements).to be_empty
    expect(client.failures).to be_empty
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

  it "rejects restore from unrelated attention or stale policy authority" do
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
        "local_passive_policy_revision" => "policy:2026-09-27:1",
      ),
    )
    @connection.update!(policy_revision: "policy:2026-09-29:changed")
    stale = FakeNetworkPeerClient.new(work: work(action: "restore"), detail: source_detail)
    expect(described_class.call(@peer, client: stale)).to include(
      outcome: "failed",
      error_code: "policy_denied",
    )
    expect(stale.acknowledgements).to be_empty
  end
end
