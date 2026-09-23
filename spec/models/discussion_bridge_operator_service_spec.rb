# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridgeOperatorService do
  fab!(:admin)
  fab!(:operator) { Fabricate(:user, email: "operator@discussionbridge.dev") }

  def claims(status: "active", paid_through_at: 30.days.from_now, identity_version: 1,
             entitlement_version: 1, operator_email: operator.email)
    {
      "status" => status,
      "entitlement_id" => SecureRandom.uuid,
      "operator_identity_id" => "discussionbridge-support-1",
      "operator_email" => operator_email,
      "identity_version" => identity_version,
      "entitlement_version" => entitlement_version,
      "plan_id" => "operator-service",
      "issued_at" => Time.zone.now,
      "paid_through_at" => paid_through_at,
      "grace_expires_at" => paid_through_at + 14.days,
      "entitlement_digest" => Digest::SHA256.hexdigest(SecureRandom.hex),
    }
  end

  it "uses one database-enforced singleton service record" do
    first = described_class.instance
    second = described_class.instance

    expect(second.id).to eq(first.id)
    expect(described_class.where(singleton_key: described_class::SINGLETON_KEY).count).to eq(1)
    expect do
      described_class.create!(
        singleton_key: described_class::SINGLETON_KEY,
        installation_id: SecureRandom.uuid,
        enrollment_id: SecureRandom.uuid,
      )
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "requires explicit administrator opt-in before an entitlement grants access" do
    service = described_class.instance
    service.apply_entitlement!(claims)

    expect(service.effective_status).to eq("inactive")
    expect(service.view_allowed?(operator)).to eq(false)
    expect(service.mutation_allowed?(operator)).to eq(false)

    service.enable!
    expect(service.reload).to have_attributes(enabled: true, status: "active")
    expect(service.operator_user).to eq(operator)
    expect(service.view_allowed?(operator)).to eq(true)
    expect(service.mutation_allowed?(operator)).to eq(true)
  end

  it "separates local enablement from requesting enrollment" do
    service = described_class.instance

    expect { service.request!(user: admin) }.to raise_error(
      ArgumentError,
      "operator service must be enabled before requesting enrollment",
    )

    service.enable!
    expect(service.reload).to have_attributes(
      enabled: true,
      status: "inactive",
      requested_at: nil,
      notification_state: "not_sent",
    )

    service.request!(user: admin)
    expect(service.reload).to have_attributes(
      enabled: true,
      status: "pending",
      requested_by: admin,
      notification_state: "queued",
    )
  end

  it "uses the centrally controlled fourteen-day grace period then becomes read-only" do
    paid_through = 1.day.ago
    service = described_class.instance
    service.enable!
    service.request!(user: admin)
    service.apply_entitlement!(claims(status: "past_due", paid_through_at: paid_through))

    expect(service.effective_status(now: paid_through + 13.days)).to eq("grace")
    expect(service.mutation_allowed?(operator, now: paid_through + 13.days)).to eq(true)
    expect(service.effective_status(now: paid_through + 15.days)).to eq("read_only")
    expect(service.view_allowed?(operator, now: paid_through + 15.days)).to eq(true)
    expect(service.mutation_allowed?(operator, now: paid_through + 15.days)).to eq(false)
  end

  it "rejects replayed entitlements and requires a newer identity version for replacement" do
    service = described_class.instance
    service.enable!
    service.request!(user: admin)
    service.apply_entitlement!(claims)

    expect { service.apply_entitlement!(claims) }.to raise_error(ArgumentError, /version is stale/)
    expect do
      service.apply_entitlement!(
        claims(
          entitlement_version: 2,
          identity_version: 1,
          operator_email: "replacement@discussionbridge.dev",
        ),
      )
    end.to raise_error(ArgumentError, /newer identity version/)
  end

  it "fails closed for revoked service while administrators retain control" do
    service = described_class.instance
    service.enable!
    service.request!(user: admin)
    service.apply_entitlement!(claims(status: "revoked"))

    expect(service.effective_status).to eq("revoked")
    expect(service.view_allowed?(operator)).to eq(false)
    expect(service.mutation_allowed?(operator)).to eq(false)
    expect(service.view_allowed?(admin)).to eq(true)
    expect(service.mutation_allowed?(admin)).to eq(true)
  end
end
