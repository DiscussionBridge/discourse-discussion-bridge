# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge Discourse network administration" do
  fab!(:admin)
  fab!(:user)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    sign_in(admin)
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "Discourse network destination",
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
  end

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

  it "keeps the feature absent until an administrator explicitly enables it" do
    get "/discussion-bridge/admin/network.json"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("network_identity")).to be_nil

    post "/discussion-bridge/admin/network/enable.json"
    expect(response).to have_http_status(:ok), response.body
    identity = response.parsed_body.fetch("network_identity")
    expect(identity).to include("enabled" => true, "ready" => true)
    expect(identity.fetch("forum_id")).to match(DiscussionBridge::DiscourseNetworkProtocol::FORUM_ID_PATTERN)

    post "/discussion-bridge/admin/network/enable.json"
    expect(response.parsed_body.dig("network_identity", "forum_id")).to eq(identity.fetch("forum_id"))
  end

  it "stores peer credentials encrypted and never returns them" do
    post "/discussion-bridge/admin/network/enable.json"
    post "/discussion-bridge/admin/network/peers.json",
         params: {
           network_peer: {
             content_connection_id: @connection.id,
             name: "National Organization",
             remote_forum_id: "dbf_11111111111111111111111111111111",
             remote_forum_name: "National Organization",
             remote_origin: "https://national.example",
             remote_connection_id: "dbc_#{"1" * 24}",
             remote_secret: "s" * 32,
             relationship: "hub_to_spoke",
             enabled: true,
           },
         },
         as: :json
    expect(response).to have_http_status(:created), response.body
    expect(response.body).not_to include("s" * 32)

    peer = DiscussionBridgeNetworkPeer.last
    expect(peer.remote_secret_ciphertext).not_to include("s" * 32)
    expect(peer.remote_secret).to eq("s" * 32)
    expect(response.parsed_body.fetch("network_peer")).to include(
      "operational" => true,
      "remote_forum_id" => "dbf_11111111111111111111111111111111",
    )
  end

  it "rotates, disables, and reauthorizes one peer identity without exposing its secret" do
    post "/discussion-bridge/admin/network/enable.json"
    peer = DiscussionBridgeNetworkPeer.create!(
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
      authorized_at: 1.hour.ago,
    )

    put "/discussion-bridge/admin/network/peers/#{peer.id}.json",
        params: { network_peer: { remote_secret: "t" * 32 } },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.body).not_to include("t" * 32)
    expect(peer.reload).to have_attributes(id: peer.id, enabled: true)
    expect(peer.remote_secret).to eq("t" * 32)
    rotated_at = peer.authorized_at

    post "/discussion-bridge/admin/network/peers/#{peer.id}/disable.json"
    expect(response).to have_http_status(:ok), response.body
    expect(peer.reload).to have_attributes(enabled: false, disabled_at: be_present)

    put "/discussion-bridge/admin/network/peers/#{peer.id}.json",
        params: { network_peer: { enabled: true } },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.body).not_to include("t" * 32)
    expect(peer.reload).to have_attributes(id: peer.id, enabled: true, disabled_at: nil)
    expect(peer.remote_secret).to eq("t" * 32)
    expect(peer.authorized_at).to be > rotated_at
    expect(DiscussionBridgeNetworkPeer.where(id: peer.id).count).to eq(1)

    sign_in(user)
    put "/discussion-bridge/admin/network/peers/#{peer.id}.json",
        params: { network_peer: { remote_secret: "v" * 32 } },
        as: :json
    expect(response).not_to have_http_status(:ok)
    expect(peer.reload.remote_secret).to eq("t" * 32)
  end

  it "creates and removes the exact Discourse network policy through explicit administration" do
    post "/discussion-bridge/admin/network/enable.json"
    post "/discussion-bridge/admin/content-connections.json",
         params: {
           content_connection: {
             name: "Regional network publication",
             platform: "discourse",
             allowed_origins: ["https://regional.example"],
             allowed_directions: %w[to_discourse from_discourse],
             allowed_lanes: [],
             default_category_id: category.id,
             network_enabled: true,
             network_peer_forum_id: "dbf_22222222222222222222222222222222",
             network_relationship: "spoke_to_hub",
           },
         },
         as: :json
    expect(response).to have_http_status(:created), response.body

    connection = DiscussionBridgeContentConnection.find(response.parsed_body.dig("content_connection", "id"))
    expect(connection.destination_policies.sole).to eq(
      DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
        peer_forum_id: "dbf_22222222222222222222222222222222",
        relationship: "spoke_to_hub",
      ),
    )
    expect(connection.policy_revision).to eq(
      DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
        peer_forum_id: "dbf_22222222222222222222222222222222",
        relationship: "spoke_to_hub",
      ),
    )
    expect(
      DiscussionBridge::DiscourseNetworkProtocol.expected_source_policy_revision(
        local_forum_id: "dbf_22222222222222222222222222222222",
        relationship: "spoke_to_hub",
      ),
    ).to eq(connection.policy_revision)
    expect(connection.policy_revision).not_to eq(
      DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
        peer_forum_id: DiscussionBridgeForumIdentity.current.forum_id,
        relationship: "spoke_to_hub",
      ),
    )

    put "/discussion-bridge/admin/content-connections/#{connection.id}.json",
        params: { content_connection: { network_enabled: false } },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(connection.reload).to have_attributes(
      network_enabled: false,
      network_peer_forum_id: nil,
      network_relationship: nil,
      catalog_required: false,
    )
    expect(connection.policy_revision).to start_with("policy:admin:")
    expect(connection.destination_policies.sole).to include(
      "destination_policy_id" => "destination:discourse_as_publisher:default",
      "profile" => "discourse_as_publisher",
      "presentation_mode" => "interactive",
    )
  end

  it "requires exact confirmation for rotation and disables every existing authorization" do
    post "/discussion-bridge/admin/network/enable.json"
    identity = DiscussionBridgeForumIdentity.current
    peer = DiscussionBridgeNetworkPeer.create!(
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

    post "/discussion-bridge/admin/network/rotate.json",
         params: { confirmation_forum_id: "dbf_#{"0" * 32}" },
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)

    old_id = identity.forum_id
    post "/discussion-bridge/admin/network/rotate.json",
         params: { confirmation_forum_id: old_id },
         as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("network_identity")).to include("enabled" => false, "ready" => false)
    expect(response.parsed_body.dig("network_identity", "retired_forum_ids")).to include(old_id)
    expect(peer.reload.enabled).to eq(false)
    expect(@connection.reload.network_enabled).to eq(false)

    put "/discussion-bridge/admin/network/peers/#{peer.id}.json",
        params: { network_peer: { enabled: true } },
        as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(peer.reload.enabled).to eq(false)
  end
end
