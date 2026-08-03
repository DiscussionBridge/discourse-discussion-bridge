# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CanonicalSource do
  it "normalizes an absolute source URL within a connection identity" do
    result = described_class.call(connection_id: "astro-demo", source_url: "HTTPS://Example.COM/article")
    expect(result.source_url).to eq("https://example.com/article")
    expect(result.identity_digest).to match(/\A[0-9a-f]{64}\z/)
    expect(result.identity_digest).to eq(Digest::SHA256.hexdigest("astro-demo\nhttps://example.com/article"))
  end

  it "rejects credentials, queries, fragments, and non-HTTP sources" do
    expect { described_class.call(connection_id: "a", source_url: "https://user@example.com/") }.to raise_error(ArgumentError)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/?token=secret") }.to raise_error(ArgumentError)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/#fragment") }.to raise_error(ArgumentError)
    expect { described_class.call(connection_id: "a", source_url: "file:///tmp/source") }.to raise_error(ArgumentError)
  end

  it "bounds durable identity inputs" do
    expect { described_class.call(connection_id: "a" * 101, source_url: "https://example.com/") }.to raise_error(ArgumentError)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/#{"a" * 2048}") }.to raise_error(ArgumentError)
  end
end
