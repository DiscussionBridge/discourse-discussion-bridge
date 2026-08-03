# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperationsController do
  fab!(:admin)
  fab!(:user)

  before { SiteSetting.discussion_bridge_enabled = true }

  it "returns the read-only operations contract to an administrator" do
    sign_in(admin)

    get "/discussion-bridge/admin/operations.json", params: { kind: "mappings", query: "astro" }

    expect(response.status).to eq(200)
    expect(response.parsed_body).to include("kind" => "mappings", "items" => [], "query" => "astro")
  end

  it "does not expose operations evidence to a non-administrator" do
    sign_in(user)

    get "/discussion-bridge/admin/operations.json"

    expect(response.status).not_to eq(200)
  end

  it "serves the nested administrator operations page through the Discourse app" do
    sign_in(admin)

    get "/admin/plugins/discourse-discussion-bridge/operations"

    expect(response.status).to eq(200)
  end
end
