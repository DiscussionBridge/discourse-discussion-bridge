# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperatorServiceAccess do
  fab!(:admin)
  fab!(:operator_user) { Fabricate(:user, active: true) }

  let(:now) { Time.zone.now.change(usec: 0) }
  let(:operation_sha256) { Digest::SHA256.hexdigest("bounded operation") }
  let(:enrollment) do
    DiscussionBridgeOperatorEnrollment.instance.tap do |record|
      record.update!(enabled: true, operator_user: operator_user)
    end
  end
  let(:entitlement) do
    DiscussionBridgeOperatorEntitlement.create!(
      entitlement_id: "dbe_44444444444444444444444444444444",
      provider_id: enrollment.provider_id,
      provider_name: enrollment.provider_name,
      forum_id: enrollment.forum_id,
      issuer_id: "dbi_44444444444444444444444444444444",
      key_id: "access-key",
      entitlement_version: 1,
      scopes: %w[observe_health apply_customer_approved_upgrade],
      signature: "A" * 86,
      payload_sha256: Digest::SHA256.hexdigest("payload"),
      payload: {},
      state: "active",
      issued_at: now - 1.hour,
      not_before: now - 1.hour,
      expires_at: now + 1.hour,
      grace_until: now + 2.hours,
      activated_at: now,
      enrolled_by: admin,
    ).tap { |record| enrollment.activate!(entitlement: record, actor: admin) }
  end

  it "binds authority to the exact operator user and entitled scope" do
    entitlement

    expect(
      described_class.authorize!(
        user: operator_user,
        scope: "observe_health",
        operation_sha256: operation_sha256,
        at: now,
      ),
    ).to eq(true)
    expect(DiscussionBridgeOperatorAuditRecord.last.outcome).to eq("applied")

    expect do
      described_class.authorize!(
        user: admin,
        scope: "observe_health",
        operation_sha256: operation_sha256,
        at: now,
      )
    end.to raise_error(DiscussionBridge::OperatorEntitlementVerifier::VerificationError)
  end

  it "rechecks that the bound operator account remains eligible" do
    entitlement
    operator_user.update!(suspended_till: now + 1.day)

    expect do
      described_class.authorize!(
        user: operator_user,
        scope: "observe_health",
        operation_sha256: operation_sha256,
        at: now,
      )
    end.to raise_error(DiscussionBridge::OperatorEntitlementVerifier::VerificationError) { |error|
      expect(error.code).to eq("scope_denied")
    }
  end

  it "permits observation but denies mutation during grace" do
    entitlement
    grace_time = now + 90.minutes

    expect(
      described_class.authorize!(
        user: operator_user,
        scope: "observe_health",
        operation_sha256: operation_sha256,
        at: grace_time,
      ),
    ).to eq(true)
    expect do
      described_class.authorize!(
        user: operator_user,
        scope: "apply_customer_approved_upgrade",
        operation_sha256: operation_sha256,
        customer_approval_id: "approval-1",
        at: grace_time,
      )
    end.to raise_error(DiscussionBridge::OperatorEntitlementVerifier::VerificationError) { |error|
      expect(error.code).to eq("scope_denied")
    }
  end

  it "requires and consumes one exact customer approval for an apply scope" do
    entitlement
    approval = DiscussionBridgeOperatorApproval.create!(
      approval_id: "approval-1",
      forum_id: enrollment.forum_id,
      provider_id: enrollment.provider_id,
      entitlement_id: entitlement.entitlement_id,
      scope: "apply_customer_approved_upgrade",
      operation_sha256: operation_sha256,
      approved_by: admin,
      expires_at: now + 30.minutes,
    )

    expect(
      described_class.authorize!(
        user: operator_user,
        scope: approval.scope,
        operation_sha256: operation_sha256,
        customer_approval_id: approval.approval_id,
        at: now,
      ),
    ).to eq(true)
    expect(approval.reload.consumed_at).to eq_time(now)

    expect do
      described_class.authorize!(
        user: operator_user,
        scope: approval.scope,
        operation_sha256: operation_sha256,
        customer_approval_id: approval.approval_id,
        at: now,
      )
    end.to raise_error(DiscussionBridge::OperatorEntitlementVerifier::VerificationError) { |error|
      expect(error.code).to eq("scope_denied")
    }
  end

  it "enables an existing current entitlement into its effective state" do
    entitlement
    enrollment.disable!

    enrollment.enable!

    expect(enrollment.reload).to be_enabled
    expect(enrollment.state).to eq("active")
  end

  it "replaces one current entitlement and preserves the replacement chain and audit" do
    entitlement
    replacement = DiscussionBridgeOperatorEntitlement.create!(
      entitlement_id: "dbe_66666666666666666666666666666666",
      provider_id: enrollment.provider_id,
      provider_name: enrollment.provider_name,
      forum_id: enrollment.forum_id,
      issuer_id: "dbi_66666666666666666666666666666666",
      key_id: "replacement-key",
      entitlement_version: 1,
      scopes: ["observe_health"],
      signature: "B" * 86,
      payload_sha256: Digest::SHA256.hexdigest("replacement payload"),
      payload: {},
      state: "active",
      issued_at: now - 1.hour,
      not_before: now - 1.hour,
      expires_at: now + 1.hour,
      grace_until: now + 2.hours,
      activated_at: now,
      enrolled_by: admin,
    )

    enrollment.activate!(entitlement: replacement, actor: admin)

    expect(entitlement.reload.state).to eq("replaced")
    expect(entitlement.replaced_by_entitlement_id).to eq(replacement.entitlement_id)
    expect(enrollment.reload.current_entitlement_id).to eq(replacement.entitlement_id)
    expect(DiscussionBridgeOperatorAuditRecord.last).to have_attributes(
      action: "enroll_entitlement",
      entitlement_id: replacement.entitlement_id,
      outcome: "approved",
    )
  end

  it "revokes authority without affecting ordinary DiscussionBridge state" do
    entitlement

    enrollment.revoke_current!(actor: admin)

    expect(entitlement.reload.state).to eq("revoked")
    expect(enrollment.reload.state).to eq("revoked")
    expect do
      described_class.authorize!(
        user: operator_user,
        scope: "observe_health",
        operation_sha256: operation_sha256,
        at: now,
      )
    end.to raise_error(DiscussionBridge::OperatorEntitlementVerifier::VerificationError) { |error|
      expect(error.code).to eq("entitlement_revoked")
    }
  end

  it "rejects a provider switch not already selected by the customer enrollment" do
    entitlement
    other_provider = entitlement.dup
    other_provider.entitlement_id = "dbe_99999999999999999999999999999999"
    other_provider.provider_id = "dbp_99999999999999999999999999999999"
    other_provider.payload_sha256 = Digest::SHA256.hexdigest("other provider")
    other_provider.save!

    expect do
      enrollment.activate!(entitlement: other_provider, actor: admin)
    end.to raise_error(ArgumentError, "entitlement provider does not match enrollment")
    expect(enrollment.reload.current_entitlement_id).to eq(entitlement.entitlement_id)
  end
end
