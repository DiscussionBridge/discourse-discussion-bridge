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
      { lane: "docs", category_id: 1, tags: [], visibility: "unlisted" },
      { lane: "docs", category_id: 2, tags: [], visibility: "unlisted" },
    ].to_json
    listed = [{ lane: "docs", category_id: 1, tags: [], visibility: "listed" }].to_json

    expect { described_class.parse(duplicate) }.to raise_error(
      described_class::ParseError,
      "duplicate lane",
    )
    expect { described_class.parse(listed) }.to raise_error(
      described_class::ParseError,
      "invalid visibility",
    )
    expect { described_class.parse("{") }.to raise_error(
      described_class::ParseError,
      "invalid JSON",
    )
  end

  it "requires the exact bounded policy schema" do
    missing = [{ lane: "docs", category_id: 1, tags: [] }].to_json
    extra = [
      { lane: "docs", category_id: 1, tags: [], visibility: "unlisted", tagz: ["typo"] },
    ].to_json
    duplicate_tags = [
      { lane: "docs", category_id: 1, tags: %w[Alpha alpha], visibility: "unlisted" },
    ].to_json

    expect { described_class.parse(missing) }.to raise_error(
      described_class::ParseError,
      "invalid lane policy schema",
    )
    expect { described_class.parse(extra) }.to raise_error(
      described_class::ParseError,
      "invalid lane policy schema",
    )
    expect { described_class.parse(duplicate_tags) }.to raise_error(
      described_class::ParseError,
      "duplicate tags",
    )
  end

  it "rejects mistyped lanes and control-bearing tags" do
    invalid = [
      [[{ lane: 1, category_id: 1, tags: [], visibility: "unlisted" }], "invalid lane"],
      [[{ lane: true, category_id: 1, tags: [], visibility: "unlisted" }], "invalid lane"],
      [[{ lane: nil, category_id: 1, tags: [], visibility: "unlisted" }], "invalid lane"],
      [
        [{ lane: "docs", category_id: 1, tags: ["bad\u0000tag"], visibility: "unlisted" }],
        "invalid tags",
      ],
      [
        [{ lane: "docs", category_id: 1, tags: ["bad\ttag"], visibility: "unlisted" }],
        "invalid tags",
      ],
      [
        [{ lane: "docs", category_id: 1, tags: ["bad\ntag"], visibility: "unlisted" }],
        "invalid tags",
      ],
    ]

    invalid.each do |value, message|
      expect { described_class.parse(value.to_json) }.to raise_error(
        described_class::ParseError,
        message,
      )
    end
  end

  it "rejects duplicate raw JSON object members" do
    value = '[{"lane":"docs","lane":"news","category_id":1,"tags":[],"visibility":"unlisted"}]'

    expect { described_class.parse(value) }.to raise_error(
      described_class::ParseError,
      /duplicate lane policy field/,
    )
  end
end
