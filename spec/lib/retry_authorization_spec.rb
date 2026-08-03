# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::RetryAuthorization do
  fab!(:administrator, :admin)

  def create_mapping(state:, updated_at: Time.zone.now)
    DiscussionBridgeConnection.create!(
      connection_id: "astro",
      canonical_source_url: "https://example.com/#{SecureRandom.hex(4)}",
      source_identity_digest: SecureRandom.hex(32),
      state: state,
      reservation_token: state == "reserved" ? SecureRandom.hex(32) : nil,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
      created_at: updated_at,
      updated_at: updated_at,
    )
  end

  it "authorizes and audits one fresh retry for a failed mapping" do
    mapping = create_mapping(state: "failed")

    result = described_class.call(mapping_id: mapping.id, administrator: administrator)

    expect(result).to have_attributes(authorized: true, reason: "retry_authorized")
    expect(mapping.reload.retry_authorized_by_id).to eq(administrator.id)
    expect(DiscussionBridgeAuditEvent.last).to have_attributes(
      effective_actor_id: administrator.id,
      outcome: "reconciliation_authorized",
      reason: "retry_authorized",
    )
    expect(described_class.call(mapping_id: mapping.id, administrator: administrator)).to have_attributes(
      authorized: false,
      reason: "retry_not_eligible",
    )
    expect(DiscussionBridgeAuditEvent.count).to eq(1)
  end

  it "authorizes a stale reservation but rejects a fresh reservation" do
    stale = create_mapping(state: "reserved", updated_at: 20.minutes.ago)
    fresh = create_mapping(state: "reserved")

    expect(described_class.call(mapping_id: stale.id, administrator: administrator).authorized).to eq(true)
    expect(described_class.call(mapping_id: fresh.id, administrator: administrator)).to have_attributes(
      authorized: false,
      reason: "retry_not_eligible",
    )
    expect(DiscussionBridgeAuditEvent.count).to eq(1)
  end

  it "revokes an unused authorization and audits the reversal" do
    mapping = create_mapping(state: "failed")
    described_class.call(mapping_id: mapping.id, administrator: administrator)

    result = described_class.revoke(mapping_id: mapping.id, administrator: administrator)

    expect(result).to have_attributes(authorized: false, reason: "retry_authorization_revoked")
    expect(mapping.reload).to have_attributes(retry_authorized_at: nil, retry_authorized_by_id: nil)
    expect(DiscussionBridgeAuditEvent.last).to have_attributes(
      outcome: "reconciliation_revoked",
      reason: "retry_authorization_revoked",
    )
  end
end
