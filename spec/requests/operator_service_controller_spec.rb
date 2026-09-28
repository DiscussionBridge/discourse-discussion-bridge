# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperatorServiceController do
  fab!(:admin)
  fab!(:user)

  before { SiteSetting.discussion_bridge_enabled = true }

  it "is default-off, customer-admin-only, and exposes no trusted public-key material" do
    sign_in(admin)
    get "/discussion-bridge/admin/operator-service.json"

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      "enabled" => false,
      "state" => "pending_enrollment",
      "provider_name" => "DiscussionBridge",
    )
    expect(response.parsed_body.fetch("providers").one?).to eq(true)

    post "/discussion-bridge/admin/operator-service/trusted-keys.json",
         params: {
           trusted_key: {
             issuer_id: "dbi_55555555555555555555555555555555",
             key_id: "request-key",
             public_key_base64url: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
             retire_at: 1.day.from_now.utc.iso8601,
           },
         }

    expect(response).to have_http_status(:ok), response.body
    expect(response.body).not_to include("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo")
    expect(response.parsed_body.dig("trusted_keys", 0)).to include(
      "issuer_id" => "dbi_55555555555555555555555555555555",
      "key_id" => "request-key",
    )

    sign_in(user)
    get "/discussion-bridge/admin/operator-service.json"
    expect(response).not_to have_http_status(:ok)
  end

  it "rejects invalid enable values and system-user operator binding" do
    sign_in(admin)

    put "/discussion-bridge/admin/operator-service.json",
        params: { operator_service: { enabled: "sometimes" } }
    expect(response).to have_http_status(:unprocessable_entity)

    put "/discussion-bridge/admin/operator-service.json",
        params: { operator_service: { operator_username: Discourse.system_user.username } }
    expect(response).to have_http_status(:unprocessable_entity)

    put "/discussion-bridge/admin/operator-service.json",
        params: { operator_service: { enabled: true, content_connection_scope: "all" } }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "does not create an approval outside the current entitlement scope" do
    enrollment = DiscussionBridgeOperatorEnrollment.instance
    enrollment.update!(enabled: true)
    entitlement = DiscussionBridgeOperatorEntitlement.create!(
      entitlement_id: "dbe_77777777777777777777777777777777",
      provider_id: enrollment.provider_id,
      provider_name: enrollment.provider_name,
      forum_id: enrollment.forum_id,
      issuer_id: "dbi_77777777777777777777777777777777",
      key_id: "request-approval-key",
      entitlement_version: 1,
      scopes: ["observe_health"],
      signature: "C" * 86,
      payload_sha256: Digest::SHA256.hexdigest("request approval payload"),
      payload: {},
      state: "active",
      issued_at: 1.hour.ago,
      not_before: 1.hour.ago,
      expires_at: 1.hour.from_now,
      grace_until: 2.hours.from_now,
      activated_at: Time.zone.now,
      enrolled_by: admin,
    )
    enrollment.activate!(entitlement: entitlement, actor: admin)
    sign_in(admin)

    post "/discussion-bridge/admin/operator-service/approvals.json",
         params: {
           approval: {
             approval_id: "approval-outside-scope",
             scope: "apply_customer_approved_upgrade",
             operation_sha256: Digest::SHA256.hexdigest("upgrade"),
             expires_at: 30.minutes.from_now.utc.iso8601,
           },
         }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiscussionBridgeOperatorApproval).not_to exist(approval_id: "approval-outside-scope")
  end
end
