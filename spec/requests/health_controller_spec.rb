# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::HealthController do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.discussion_bridge_enabled = true
  end

  it "returns the read-only health contract to an administrator" do
    sign_in(admin)

    get "/discussion-bridge/admin/health.json"

    expect(response.status).to eq(200)
    expect(response.parsed_body).to include("features", "connection", "operating_identity", "forum_authority", "mappings", "audits", "readiness")
    expect(response.parsed_body.dig("connection")).not_to have_key("credential")
  end

  it "does not expose health data to a non-administrator" do
    sign_in(user)

    get "/discussion-bridge/admin/health.json"

    expect(response.status).not_to eq(200)
  end

  it "serves the nested administrator page through the Discourse app" do
    sign_in(admin)

    get "/admin/plugins/discourse-discussion-bridge/health"

    expect(response.status).to eq(200)
  end
end
