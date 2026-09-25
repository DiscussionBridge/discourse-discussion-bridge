# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperatorEntitlementVerifier do
  fab!(:admin)

  before do
    @key = OpenSSL::PKey::RSA.generate(2048)
    @service = DiscussionBridgeOperatorService.instance
    @service.enable!
    @service.request!(user: admin)
  end

  def payload(overrides = {})
    paid_through = 30.days.from_now.change(usec: 0)
    {
      "schema" => 2,
      "issuer" => described_class::ISSUER,
      "audience" => described_class::AUDIENCE,
      "provider_id" => "discussionbridge",
      "installation_id" => @service.installation_id,
      "enrollment_id" => @service.enrollment_id,
      "entitlement_id" => SecureRandom.uuid,
      "operator_identity_id" => "discussionbridge-support-1",
      "operator_email" => "operator@discussionbridge.dev",
      "identity_version" => 1,
      "entitlement_version" => 1,
      "plan_id" => "operator-service",
      "status" => "active",
      "issued_at" => Time.zone.now.change(usec: 0).iso8601,
      "paid_through_at" => paid_through.iso8601,
      "grace_period_days" => 14,
      "grace_expires_at" => (paid_through + 14.days).iso8601,
      "site_url" => Discourse.base_url,
    }.merge(overrides)
  end

  it "normalizes a legacy schema-one entitlement to the first-party provider" do
    value = payload.except("provider_id").merge("schema" => 1)
    claims = described_class.call(
      payload: value,
      signature: signature(value),
      service: @service,
      public_key_pem: @key.public_key.to_pem,
    )

    expect(claims.fetch("provider_id")).to eq("discussionbridge")
  end

  it "rejects a provider mismatch and an email outside the provider registry" do
    [
      payload("provider_id" => "unapproved-partner"),
      payload("operator_email" => "operator@example.com"),
    ].each do |invalid|
      expect do
        described_class.call(
          payload: invalid,
          signature: signature(invalid),
          service: @service,
          public_key_pem: @key.public_key.to_pem,
        )
      end.to raise_error(ArgumentError, "entitlement is invalid")
    end
  end

  def signature(value)
    Base64.strict_encode64(@key.sign("SHA256", described_class.canonical_json(value)))
  end

  it "accepts an exact installation-bound signed entitlement" do
    value = payload
    claims = described_class.call(
      payload: value,
      signature: signature(value),
      service: @service,
      public_key_pem: @key.public_key.to_pem,
    )

    expect(claims).to include(
      "operator_email" => "operator@discussionbridge.dev",
      "grace_period_days" => 14,
      "identity_version" => 1,
      "entitlement_version" => 1,
    )
    expect(claims.fetch("entitlement_digest")).to match(/\A[0-9a-f]{64}\z/)
  end

  it "rejects modified, cross-installation, and customer-controlled grace claims" do
    valid = payload
    [
      valid.merge("operator_email" => "attacker@example.com"),
      valid.merge("installation_id" => SecureRandom.uuid),
      valid.merge("grace_period_days" => 90),
      valid.merge("grace_expires_at" => 90.days.from_now.iso8601),
    ].each do |invalid|
      expect do
        described_class.call(
          payload: invalid,
          signature: signature(valid),
          service: @service,
          public_key_pem: @key.public_key.to_pem,
        )
      end.to raise_error(ArgumentError, "entitlement is invalid")
    end
  end
end

