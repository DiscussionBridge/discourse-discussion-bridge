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
    trusted_key!(
      issuer_id: "dbi_44444444444444444444444444444444",
      key_id: "access-key",
    )
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
    trusted_key!(
      issuer_id: "dbi_66666666666666666666666666666666",
      key_id: "replacement-key",
    )
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

    original_key = DiscussionBridgeOperatorTrustedKey.find_by!(
      issuer_id: entitlement.issuer_id,
      key_id: entitlement.key_id,
    )
    enrollment.revoke_trusted_key!(trusted_key_id: original_key.id, actor: admin, at: now)

    expect(entitlement.reload.state).to eq("replaced")
    expect(replacement.reload.state).to eq("active")
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: replacement.entitlement_id,
      state: "active",
    )
    expect(DiscussionBridgeOperatorAuditRecord.last).to have_attributes(
      action: "revoke_trusted_key",
      entitlement_id: nil,
      target_id: "#{original_key.issuer_id}:#{original_key.key_id}",
    )
  end

  it "revokes every effective entitlement for the key without touching unrelated or terminal history" do
    key = trusted_key!(
      issuer_id: "dbi_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      key_id: "verified-not-current",
    )
    active = create_entitlement!(
      entitlement_id: "dbe_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      issuer_id: key.issuer_id,
      key_id: key.key_id,
    )
    grace = create_entitlement!(
      entitlement_id: "dbe_a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
      issuer_id: key.issuer_id,
      key_id: key.key_id,
    )
    grace.update!(state: "grace_read_only", expires_at: now - 1.minute)
    terminal = create_entitlement!(
      entitlement_id: "dbe_a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2",
      issuer_id: key.issuer_id,
      key_id: key.key_id,
    )
    terminal.update!(state: "replaced")
    unrelated_key = trusted_key!(
      issuer_id: key.issuer_id,
      key_id: "unrelated-key",
    )
    unrelated = create_entitlement!(
      entitlement_id: "dbe_a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3",
      issuer_id: unrelated_key.issuer_id,
      key_id: unrelated_key.key_id,
    )

    enrollment.revoke_trusted_key!(trusted_key_id: key.id, actor: admin, at: now)

    expect(active.reload).to have_attributes(state: "revoked", revoked_at: now)
    expect(grace.reload).to have_attributes(state: "revoked", revoked_at: now)
    expect(terminal.reload).to have_attributes(state: "replaced", revoked_at: nil)
    expect(unrelated.reload).to have_attributes(state: "active", revoked_at: nil)
    expect(enrollment.reload).to have_attributes(current_entitlement_id: nil, state: "pending_enrollment")
    expect(DiscussionBridgeOperatorAuditRecord.last(3).map(&:action)).to eq(
      %w[revoke_entitlement revoke_entitlement revoke_trusted_key],
    )
    expect(DiscussionBridgeOperatorAuditRecord.last).to have_attributes(entitlement_id: nil)
  end

  it "revokes the replacement when both entitlements use the revoked key" do
    original = entitlement
    replacement = create_entitlement!(
      entitlement_id: "dbe_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      issuer_id: original.issuer_id,
      key_id: original.key_id,
    )
    enrollment.activate!(entitlement: replacement, actor: admin, at: now)
    key = DiscussionBridgeOperatorTrustedKey.find_by!(
      issuer_id: original.issuer_id,
      key_id: original.key_id,
    )

    enrollment.revoke_trusted_key!(trusted_key_id: key.id, actor: admin, at: now)

    expect(original.reload.state).to eq("replaced")
    expect(replacement.reload.state).to eq("revoked")
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: replacement.entitlement_id,
      state: "revoked",
    )
  end

  it "preserves a same-issuer replacement using a different key and rejects the stale entitlement" do
    original = entitlement
    replacement_key = trusted_key!(
      issuer_id: original.issuer_id,
      key_id: "same-issuer-replacement",
    )
    replacement = create_entitlement!(
      entitlement_id: "dbe_cccccccccccccccccccccccccccccccc",
      issuer_id: replacement_key.issuer_id,
      key_id: replacement_key.key_id,
    )
    enrollment.activate!(entitlement: replacement, actor: admin, at: now)

    expect do
      enrollment.activate!(entitlement: original, actor: admin, at: now)
    end.to raise_error(DiscussionBridge::OperatorEntitlementVerifier::VerificationError) { |error|
      expect(error.code).to eq("entitlement_replaced")
    }
    expect(enrollment.reload.current_entitlement_id).to eq(replacement.entitlement_id)

    original_key = DiscussionBridgeOperatorTrustedKey.find_by!(
      issuer_id: original.issuer_id,
      key_id: original.key_id,
    )

    enrollment.revoke_trusted_key!(trusted_key_id: original_key.id, actor: admin, at: now)

    expect do
      enrollment.activate!(entitlement: original, actor: admin, at: now)
    end.to raise_error(DiscussionBridge::OperatorEntitlementVerifier::VerificationError) { |error|
      expect(error.code).to eq("entitlement_invalid_signature")
    }
    expect(original.reload.state).to eq("replaced")
    expect(replacement.reload.state).to eq("active")
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: replacement.entitlement_id,
      state: "active",
    )
  end

  it "rolls back key and entitlement state when revocation audit persistence fails" do
    active = entitlement
    baseline_audits = DiscussionBridgeOperatorAuditRecord.order(:id).pluck(
      :action,
      :entitlement_id,
      :outcome,
    )
    key = DiscussionBridgeOperatorTrustedKey.find_by!(
      issuer_id: active.issuer_id,
      key_id: active.key_id,
    )
    allow(DiscussionBridge::OperatorAudit).to receive(:record!).and_raise("audit unavailable")

    expect do
      enrollment.revoke_trusted_key!(trusted_key_id: key.id, actor: admin, at: now)
    end.to raise_error("audit unavailable")

    expect(key.reload).to have_attributes(may_issue: true, revoked_at: nil)
    expect(active.reload).to have_attributes(state: "active", revoked_at: nil)
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: active.entitlement_id,
      state: "active",
    )
    expect(
      DiscussionBridgeOperatorAuditRecord.order(:id).pluck(:action, :entitlement_id, :outcome),
    ).to eq(baseline_audits)
  end

  it "rolls back all revocation effects when the final key audit fails" do
    active = entitlement
    baseline_audits = DiscussionBridgeOperatorAuditRecord.order(:id).pluck(
      :action,
      :entitlement_id,
      :outcome,
    )
    key = DiscussionBridgeOperatorTrustedKey.find_by!(
      issuer_id: active.issuer_id,
      key_id: active.key_id,
    )
    allow(DiscussionBridge::OperatorAudit).to receive(:record!).and_wrap_original do |method, **attributes|
      raise "key audit unavailable" if attributes.fetch(:action) == "revoke_trusted_key"

      method.call(**attributes)
    end

    expect do
      enrollment.revoke_trusted_key!(trusted_key_id: key.id, actor: admin, at: now)
    end.to raise_error("key audit unavailable")

    expect(key.reload).to have_attributes(may_issue: true, revoked_at: nil)
    expect(active.reload).to have_attributes(state: "active", revoked_at: nil)
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: active.entitlement_id,
      state: "active",
    )
    expect(
      DiscussionBridgeOperatorAuditRecord.order(:id).pluck(:action, :entitlement_id, :outcome),
    ).to eq(baseline_audits)
  end

  it "rejects a stale revoked entitlement while its signing key remains trusted" do
    revoked = entitlement
    enrollment.revoke_current!(actor: admin)
    key = DiscussionBridgeOperatorTrustedKey.find_by!(
      issuer_id: revoked.issuer_id,
      key_id: revoked.key_id,
    )

    expect(key).to be_may_issue
    expect do
      enrollment.activate!(entitlement: revoked, actor: admin, at: now)
    end.to raise_error(DiscussionBridge::OperatorEntitlementVerifier::VerificationError) { |error|
      expect(error.code).to eq("entitlement_revoked")
    }
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: revoked.entitlement_id,
      state: "revoked",
    )
  end

  it "does not treat key retirement as revocation of existing authority" do
    active = entitlement
    key = DiscussionBridgeOperatorTrustedKey.find_by!(
      issuer_id: active.issuer_id,
      key_id: active.key_id,
    )
    key.update!(retire_at: now - 1.second)

    expect(
      described_class.authorize!(
        user: operator_user,
        scope: "observe_health",
        operation_sha256: operation_sha256,
        at: now,
      ),
    ).to eq(true)
    expect(active.reload.effective_state(at: now)).to eq("active")
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

  def trusted_key!(issuer_id:, key_id:)
    DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: issuer_id,
      key_id: key_id,
      public_key_base64url: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
      enrolled_by: admin,
      enrolled_at: now,
    )
  end

  def create_entitlement!(entitlement_id:, issuer_id:, key_id:)
    DiscussionBridgeOperatorEntitlement.create!(
      entitlement_id: entitlement_id,
      provider_id: enrollment.provider_id,
      provider_name: enrollment.provider_name,
      forum_id: enrollment.forum_id,
      issuer_id: issuer_id,
      key_id: key_id,
      entitlement_version: 1,
      scopes: ["observe_health"],
      signature: "D" * 86,
      payload_sha256: Digest::SHA256.hexdigest(entitlement_id),
      payload: {},
      state: "active",
      issued_at: now - 1.hour,
      not_before: now - 1.hour,
      expires_at: now + 1.hour,
      grace_until: now + 2.hours,
      activated_at: now,
      enrolled_by: admin,
    )
  end
end
