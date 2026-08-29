# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::HealthController do
  fab!(:admin)
  fab!(:user)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Main Ghost",
      platform: "ghost",
      allowed_origins: ["https://publisher.example"],
      allowed_directions: %w[to_discourse from_discourse],
      allowed_lanes: [],
    )
  end

  it "returns the native product overview without exposing a connection secret" do
    sign_in(admin)

    get "/discussion-bridge/admin/health.json"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("product", "metrics", "directions", "readiness", "connections")
    expect(response.parsed_body.dig("metrics", "content_connections")).to eq(1)
    expect(response.parsed_body.dig("connections", 0, "public_id")).to eq(@connection.public_id)
    expect(response.body).not_to include(@secret)
  end

  it "exports a redacted support bundle to an administrator" do
    sign_in(admin)

    get "/discussion-bridge/admin/support-bundle.json"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("generated_at", "overview", "reconciliation")
    expect(response.body).not_to include(@secret)
    expect(response.body).not_to include(@connection.secret_digest)
  end

  it "does not expose product state to a non-administrator" do
    sign_in(user)

    get "/discussion-bridge/admin/health.json"

    expect(response).not_to have_http_status(:ok)
  end
end
