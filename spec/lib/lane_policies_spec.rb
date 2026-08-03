# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::LanePolicies do
  let(:policies) do
    [{ lane: "docs", category_id: 12, tags: %w[alpha docs], visibility: "unlisted" }].to_json
  end

  it "resolves an explicitly configured lane" do
    result = described_class.resolve(value: policies, lane: "docs")

    expect(result.allowed).to eq(true)
    expect(result.category_id).to eq(12)
    expect(result.tags).to eq(%w[alpha docs])
  end

  it "fails closed for missing and unknown lanes when policies are configured" do
    expect(described_class.resolve(value: policies, lane: nil).reason).to eq("lane_required")
    expect(described_class.resolve(value: policies, lane: "news").reason).to eq("lane_denied")
  end

  it "retains the global policy path when no lane policies are configured" do
    result = described_class.resolve(value: "[]", lane: nil)

    expect(result.configured).to eq(false)
    expect(result.allowed).to eq(true)
    expect(result.reason).to eq("global_policy")
  end

  it "rejects duplicate lanes, listed visibility, and malformed JSON" do
    duplicate = [
      { lane: "docs", category_id: 1 },
      { lane: "docs", category_id: 2 },
    ].to_json
    listed = [{ lane: "docs", category_id: 1, visibility: "listed" }].to_json

    expect { described_class.parse(duplicate) }.to raise_error(described_class::ParseError)
    expect { described_class.parse(listed) }.to raise_error(described_class::ParseError)
    expect { described_class.parse("{") }.to raise_error(described_class::ParseError)
  end
end
