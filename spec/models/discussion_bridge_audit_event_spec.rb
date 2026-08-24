# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridgeAuditEvent do
  let(:valid_attributes) do
    {
      connection_id: "astro",
      source_identity_digest: "a" * 64,
      outcome: "rejected",
      reason: "origin_denied",
      requested_state: { "adapter_id" => "astro" },
      effective_state: {},
    }
  end

  it "accepts only the durable audit allowlist" do
    expect(described_class.new(valid_attributes)).to be_valid
  end

  it "rejects secrets and nested payloads rather than persisting them" do
    secret = described_class.new(valid_attributes.merge(requested_state: { "secret" => "do-not-store" }))
    nested = described_class.new(valid_attributes.merge(requested_state: { "adapter_id" => { "token" => "x" } }))

    expect(secret).not_to be_valid
    expect(nested).not_to be_valid
  end

  it "rejects oversized or control-bearing durable evidence" do
    oversized = described_class.new(
      valid_attributes.merge(requested_state: { "adapter_id" => "x" * 2049 }),
    )
    too_many = described_class.new(
      valid_attributes.merge(requested_state: { "tags" => Array.new(21, "tag") }),
    )
    control = described_class.new(
      valid_attributes.merge(requested_state: { "adapter_id" => "bad\u0000value" }),
    )

    expect(oversized).not_to be_valid
    expect(too_many).not_to be_valid
    expect(control).not_to be_valid
  end
end
