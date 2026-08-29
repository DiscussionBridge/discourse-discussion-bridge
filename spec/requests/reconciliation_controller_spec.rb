# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::ReconciliationController do
  fab!(:admin)
  fab!(:user)

  let!(:record) do
    DiscussionBridgeBridgeRecord.create!(
      resource_id: SecureRandom.uuid,
      direction: "to_discourse",
      state: "attention",
      title: "Missing discussion",
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
    )
  end

  before { SiteSetting.discussion_bridge_enabled = true }

  it "returns the grouped Bridge Record issue census to an administrator" do
    sign_in(admin)

    get "/discussion-bridge/admin/reconciliation.json", params: { severity: "critical", query: record.resource_id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("severity" => "critical", "query" => record.resource_id)
    expect(response.parsed_body.dig("summary", "critical")).to eq(2)
    expect(response.parsed_body.fetch("items").map { |item| item.fetch("code") }).to contain_exactly(
      "topic_missing",
      "active_binding_missing",
    )
  end

  it "exports the current reconciliation report" do
    sign_in(admin)

    get "/discussion-bridge/admin/reconciliation/report.json"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("summary", "total")).to eq(2)
  end

  it "rejects invalid filters and non-administrator access" do
    sign_in(admin)
    get "/discussion-bridge/admin/reconciliation.json", params: { page: 10_001 }
    expect(response).to have_http_status(:unprocessable_entity)

    sign_in(user)
    get "/discussion-bridge/admin/reconciliation.json"
    expect(response).not_to have_http_status(:ok)
  end
end
