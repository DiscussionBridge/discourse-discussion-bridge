# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::ConnectionRequest do
  def parameters(overrides = {})
    ActionController::Parameters.new(
      {
        connection_id: "astro",
        adapter_id: "astro",
        source_url: "https://example.com/article",
        title: "Companion discussion",
        visibility: "unlisted",
        lane: "docs",
        correlation_id: "request-1",
        category_id: 1,
        tags: ["docs"],
      }.merge(overrides),
    )
  end

  it "accepts the exact bounded request schema" do
    expect(described_class.call(parameters)).to include(
      connection_id: "astro",
      source_url: "https://example.com/article",
      title: "Companion discussion",
    )
  end

  it "rejects unknown, nested, control, and oversized values before orchestration" do
    invalid = [
      parameters(unknown: "field"),
      parameters(adapter_id: { nested: true }),
      parameters(correlation_id: "bad\u0000value"),
      parameters(adapter_id: "a" * 101),
      parameters(tags: Array.new(21, "tag")),
      parameters(tags: %w[Docs docs]),
      parameters(category_id: "01"),
    ]

    invalid.each { |value| expect { described_class.call(value) }.to raise_error(ArgumentError) }
  end

  it "rejects every non-object connection container before conversion" do
    [nil, false, true, "connection", 1, [], [parameters]].each do |value|
      expect { described_class.call(value) }.to raise_error(ArgumentError, /must be an object/)
    end
  end
end
