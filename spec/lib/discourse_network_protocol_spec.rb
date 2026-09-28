# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::DiscourseNetworkProtocol do
  fab!(:admin)
  fab!(:category)

  before do
    @original_forum_name = ENV["DISCUSSIONBRIDGE_FORUM_NAME"]
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "Local Forum"
    @identity = DiscussionBridgeForumIdentity.enable!(actor: admin)
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "Network destination",
      platform: "discourse",
      allowed_origins: ["https://national.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: ["network"],
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

  def fixture(name)
    JSON.parse(
      File.read(
        File.expand_path("../fixtures/#{name}", __dir__),
      ),
    )
  end

  it "preserves an explicitly enabled identity and requires rotation after a clone" do
    expect(described_class::FORUM_ID_PATTERN).to match(@identity.forum_id)
    expect(DiscussionBridgeForumIdentity.enable!(actor: admin).forum_id).to eq(@identity.forum_id)

    Discourse.stubs(:base_url).returns("https://clone.example")
    expect { DiscussionBridgeForumIdentity.enable!(actor: admin) }.to raise_error(
      ArgumentError,
      /explicit rotation/,
    )
    old_id = @identity.forum_id
    @identity.rotate!(actor: admin)
    expect(@identity).to have_attributes(enabled: false, site_origin: "https://clone.example")
    expect(@identity.forum_id).not_to eq(old_id)
    expect(@identity.retired_forum_ids).to include(old_id)
    expect(@peer.reload.enabled).to eq(false)
    expect(@connection.reload.network_enabled).to eq(false)
  end

  it "accepts the exact network fixture and appends the local route once" do
    provenance = fixture("network-source-detail.json").fetch("network_provenance")
    accepted = described_class.validate_provenance!(
      provenance,
      peer: @peer,
      local_identity: @identity,
    )
    appended = described_class.append_local_route!(accepted, local_identity: @identity)

    expect(appended.fetch("route_forum_ids")).to eq(
      [@peer.remote_forum_id, @identity.forum_id],
    )
  end

  it "uses the exact Discourse profile and accepts contract chunked transport" do
    policy = described_class.destination_policy(
      peer_forum_id: @peer.remote_forum_id,
      relationship: @peer.relationship,
    )
    expect(policy).to include(
      "profile" => "discourse_as_publisher",
      "presentation_mode" => "interactive",
      "catalog_revision" => described_class::CATALOG_REVISION,
    )
    expect(DiscussionBridge::ConnectionCapability.valid_destination_policies?([policy])).to eq(true)

    detail = fixture("network-source-detail.json")
    content = detail.dig("content_transport", "content_html")
    detail["content_transport"] = {
      "mode" => "chunked",
      "media_type" => DiscussionBridge::SourcePublicationProtocol::MEDIA_TYPE,
      "byte_length" => content.bytesize,
      "sha256" => Digest::SHA256.hexdigest(content),
      "chunk_count" => 1,
      "decoded_chunk_maximum_bytes" => DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES,
    }
    parsed = DiscussionBridge::NetworkSourceDetail.call(payload: detail, content_html: content)
    expect(parsed.fetch("content_html")).to eq(content)
  end

  it "rejects self, repeated, wrong-direction, and over-limit routes before mutation" do
    base = fixture("network-source-detail.json").fetch("network_provenance")
    invalid = [
      base.merge("origin_forum_id" => @identity.forum_id),
      base.merge("route_forum_ids" => [@peer.remote_forum_id, @peer.remote_forum_id]),
      base.merge("relationship" => "spoke_to_hub"),
      base.merge(
        "route_forum_ids" => Array.new(9) do |index|
          "dbf_#{index.to_s(16).rjust(32, "0")}"
        end,
      ),
    ]

    invalid.each do |provenance|
      expect do
        described_class.validate_provenance!(
          provenance,
          peer: @peer,
          local_identity: @identity,
        )
      end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error)
    end
    expect(DiscussionBridgeNetworkReplay.count).to eq(0)
  end

  it "retains exact operation replay and rejects operation-id reuse with changed input" do
    detail = fixture("network-source-detail.json")
    provenance = detail.fetch("network_provenance")
    immutable = described_class.immutable_operation(
      source_detail: detail,
      provenance: provenance,
      policy_revision: "policy:2026-09-27:1",
    )
    first = DiscussionBridge::NetworkReplayRegistry.reserve!(
      peer: @peer,
      provenance: provenance,
      immutable_operation: immutable,
      correlation_id: detail.fetch("correlation_id"),
    )
    DiscussionBridge::NetworkReplayRegistry.retain!(
      record: first.record,
      result: { "outcome" => "created" },
    )
    replay = DiscussionBridge::NetworkReplayRegistry.reserve!(
      peer: @peer,
      provenance: provenance,
      immutable_operation: immutable,
      correlation_id: detail.fetch("correlation_id"),
    )

    expect(replay.replay).to eq(true)
    expect(replay.record.retained_result).to eq("outcome" => "created")
    changed = immutable.merge("source_revision" => "post:501:version:3")
    expect do
      DiscussionBridge::NetworkReplayRegistry.reserve!(
        peer: @peer,
        provenance: provenance,
        immutable_operation: changed,
        correlation_id: detail.fetch("correlation_id"),
      )
    end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) do |error|
      expect(error.error_code).to eq("operation_replay_mismatch")
    end
  end
end
