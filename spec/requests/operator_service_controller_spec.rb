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
    DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: "dbi_77777777777777777777777777777777",
      key_id: "request-approval-key",
      public_key_base64url: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
      enrolled_by: admin,
      enrolled_at: Time.zone.now,
    )
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

  it "enrolls and revokes a signed entitlement through the admin paths atomically" do
    sign_in(admin)
    put "/discussion-bridge/admin/operator-service.json",
        params: { operator_service: { enabled: true } }
    expect(response).to have_http_status(:ok), response.body

    signing_key = OpenSSL::PKey.generate_key("ED25519")
    issuer_id = "dbi_#{"6" * 32}"
    key_id = "request-revocation-key"
    post "/discussion-bridge/admin/operator-service/trusted-keys.json",
         params: {
           trusted_key: {
             issuer_id: issuer_id,
             key_id: key_id,
             public_key_base64url: raw_public_key(signing_key),
           },
         }
    expect(response).to have_http_status(:ok), response.body
    trusted_key = DiscussionBridgeOperatorTrustedKey.find_by!(issuer_id: issuer_id, key_id: key_id)
    enrollment = DiscussionBridgeOperatorEnrollment.instance
    entitlement_id = "dbe_#{"6" * 32}"
    payload = signed_payload(
      signing_key: signing_key,
      enrollment: enrollment,
      issuer_id: issuer_id,
      key_id: key_id,
      entitlement_id: entitlement_id,
    )

    post "/discussion-bridge/admin/operator-service/entitlements.json",
         params: JSON.generate("entitlement" => payload),
         headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:ok), response.body
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: entitlement_id,
      state: "active",
    )

    delete "/discussion-bridge/admin/operator-service/trusted-keys/#{trusted_key.id}.json"

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("entitlement", "state")).to eq("revoked")
    expect(trusted_key.reload).to have_attributes(may_issue: false, revoked_at: be_present)
    expect(DiscussionBridgeOperatorEntitlement.find_by!(entitlement_id: entitlement_id)).to have_attributes(
      state: "revoked",
      revoked_at: be_present,
    )
    expect(enrollment.reload.state).to eq("revoked")
    expect(DiscussionBridgeOperatorAuditRecord.order(:id).pluck(:action, :entitlement_id).last(3)).to eq(
      [
        ["enroll_entitlement", entitlement_id],
        ["revoke_entitlement", entitlement_id],
        ["revoke_trusted_key", nil],
      ],
    )
  end

  it "rejects invalid UTF-8 request bytes before creating an entitlement" do
    sign_in(admin)
    invalid_body = "{\"entitlement\":\"\xFF\"}".b

    post "/discussion-bridge/admin/operator-service/entitlements.json",
         params: invalid_body,
         headers: { "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(:bad_request)
    expect(DiscussionBridgeOperatorEntitlement.count).to eq(0)
  end

  it "returns a bounded validation error when replacement is attempted while disabled" do
    enrollment = DiscussionBridgeOperatorEnrollment.instance
    signing_key = OpenSSL::PKey.generate_key("ED25519")
    issuer_id = "dbi_#{"8" * 32}"
    key_id = "disabled-replacement-key"
    DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: issuer_id,
      key_id: key_id,
      public_key_base64url: raw_public_key(signing_key),
      enrolled_by: admin,
      enrolled_at: Time.zone.now,
    )
    payload = signed_payload(
      signing_key: signing_key,
      enrollment: enrollment,
      issuer_id: issuer_id,
      key_id: key_id,
      entitlement_id: "dbe_#{"8" * 32}",
    )
    sign_in(admin)

    post "/discussion-bridge/admin/operator-service/entitlements.json",
         params: JSON.generate("entitlement" => payload),
         headers: { "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include(
      "error_code" => "validation_failed",
      "message" => "operator service is disabled",
    )
    expect(enrollment.reload).to have_attributes(enabled: false, current_entitlement_id: nil)
    expect(DiscussionBridgeOperatorEntitlement).not_to exist(entitlement_id: payload.fetch("entitlement_id"))
  end

  def raw_public_key(key)
    raw = OpenSSL::ASN1.decode(key.public_to_der).value.last.value
    Base64.urlsafe_encode64(raw, padding: false)
  end

  def signed_payload(signing_key:, enrollment:, issuer_id:, key_id:, entitlement_id:)
    now = Time.zone.now.change(usec: 0)
    claims = {
      "entitlement_version" => 1,
      "entitlement_id" => entitlement_id,
      "provider_id" => enrollment.provider_id,
      "provider_name" => enrollment.provider_name,
      "forum_id" => enrollment.forum_id,
      "issuer_id" => issuer_id,
      "issued_at" => (now - 1.minute).iso8601,
      "not_before" => (now - 1.minute).iso8601,
      "expires_at" => (now + 1.hour).iso8601,
      "grace_until" => (now + 2.hours).iso8601,
      "scopes" => ["observe_health"],
      "key_id" => key_id,
    }
    canonical = DiscussionBridge::OperatorCanonicalJson.generate(claims)
    signature = signing_key.sign(
      nil,
      DiscussionBridge::OperatorEntitlementVerifier::SIGNING_DOMAIN + canonical,
    )
    claims.merge("signature" => Base64.urlsafe_encode64(signature, padding: false))
  end
end
