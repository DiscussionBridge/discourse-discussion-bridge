# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::ReconciliationController do
  fab!(:admin)
  fab!(:user)

  let!(:failed_mapping) do
    DiscussionBridgeConnection.create!(
      connection_id: "astro",
      canonical_source_url: "https://example.com/failed",
      source_identity_digest: SecureRandom.hex(32),
      state: "failed",
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
    )
  end

  before { SiteSetting.discussion_bridge_enabled = true }

  it "returns the read-only reconciliation contract to an administrator" do
    sign_in(admin)

    get "/discussion-bridge/admin/reconciliation.json", params: { severity: "high", query: "astro" }

    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "severity" => "high",
      "query" => "astro",
      "items" => [],
      "summary" => { "critical" => 0, "high" => 0, "medium" => 0, "total" => 0 },
    )
  end

  it "does not expose reconciliation evidence to a non-administrator" do
    sign_in(user)

    get "/discussion-bridge/admin/reconciliation.json"

    expect(response.status).not_to eq(200)
  end

  it "serves the nested administrator reconciliation page through the Discourse app" do
    sign_in(admin)

    get "/admin/plugins/discourse-discussion-bridge/reconciliation"

    expect(response.status).to eq(200)
  end

  it "allows only an administrator to authorize an eligible retry" do
    sign_in(admin)

    post "/discussion-bridge/admin/reconciliation/#{failed_mapping.id}/authorize-retry.json"

    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "authorized" => true,
      "reason" => "retry_authorized",
      "mapping_id" => failed_mapping.id,
    )
    expect(failed_mapping.reload.retry_authorized_by_id).to eq(admin.id)
  end

  it "denies retry authorization to a non-administrator" do
    sign_in(user)

    post "/discussion-bridge/admin/reconciliation/#{failed_mapping.id}/authorize-retry.json"

    expect(response.status).not_to eq(200)
    expect(failed_mapping.reload.retry_authorized_at).to be_nil
    expect(DiscussionBridgeAuditEvent.count).to eq(0)
  end

  it "lets an administrator revoke an unused retry authorization" do
    sign_in(admin)
    DiscussionBridge::RetryAuthorization.call(mapping_id: failed_mapping.id, administrator: admin)

    post "/discussion-bridge/admin/reconciliation/#{failed_mapping.id}/revoke-retry.json"

    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "authorized" => false,
      "reason" => "retry_authorization_revoked",
    )
    expect(failed_mapping.reload.retry_authorized_at).to be_nil
  end
end
