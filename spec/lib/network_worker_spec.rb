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

  def work(action: "publish")
    {
      "work_id" => "dbw_#{"1" * 32}",
      "connection_id" => @peer.remote_connection_id,
      "resource_id" => source_detail.fetch("resource_id"),
      "action" => action,
      "source_revision" => source_detail.fetch("source_revision"),
      "source_revision_sequence" => source_detail.fetch("source_revision_sequence"),
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
end
