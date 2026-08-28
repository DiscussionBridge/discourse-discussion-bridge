# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperationsIndex do
  fab!(:actor, :user)

  let!(:mapping) do
    DiscussionBridgeConnection.create!(
      connection_id: "astro-alpha",
      canonical_source_url: "https://example.com/articles/health",
      source_identity_digest: Digest::SHA256.hexdigest("mapping-health"),
      state: "complete",
      topic_id: 123,
      effective_actor_id: actor.id,
      lane: "articles",
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
    )
  end

  let!(:audit) do
    DiscussionBridgeAuditEvent.create!(
      correlation_id: "correlation-health",
      connection_id: "astro-alpha",
      adapter_id: "astro",
      source_identity_digest: mapping.source_identity_digest,
      topic_id: mapping.topic_id,
      effective_actor_id: actor.id,
      outcome: "created",
      reason: "forum_policy_applied",
      requested_state: {},
      effective_state: {},
    )
  end

  it "returns searchable safe mapping evidence" do
    result = described_class.call(kind: "mappings", query: "articles/health", filter: "complete")

    expect(result.dig(:pagination, :total)).to eq(1)
    expect(result[:items].first).to include(
      id: mapping.id,
      source_url: mapping.canonical_source_url,
      state: "complete",
      actor: { id: actor.id, username: actor.username },
    )
    expect(result.to_json).not_to include("requested_state", "effective_state", "secret")
  end

  it "returns searchable safe audit evidence" do
    result = described_class.call(kind: "audits", query: "correlation-health", filter: "created")

    expect(result.dig(:pagination, :total)).to eq(1)
    expect(result[:items].first).to include(
      id: audit.id,
      correlation_id: "correlation-health",
      outcome: "created",
      reason: "forum_policy_applied",
    )
    expect(result.to_json).not_to include("requested_state", "effective_state", "secret")
  end

  it "rejects invalid and unbounded page inputs" do
    expect { described_class.call(kind: "mappings", page: "not-a-page") }.to raise_error(ArgumentError, "invalid page")
    expect { described_class.call(kind: "mappings", page: described_class::MAX_PAGE + 1) }.to raise_error(ArgumentError, "invalid page")
  end
end
