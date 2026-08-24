# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CanonicalSource do
  it "normalizes an absolute source URL within a connection identity" do
    result = described_class.call(connection_id: "astro-demo", source_url: "HTTPS://Example.COM/article")
    expect(result.source_url).to eq("https://example.com/article")
    expect(result.identity_digest).to match(/\A[0-9a-f]{64}\z/)
    expect(result.identity_digest).to eq(Digest::SHA256.hexdigest("astro-demo\nhttps://example.com/article"))
  end

  it "collapses accepted aliases to one HTTP resource identity" do
    variants = [
      "https://example.com/a/b~c",
      "https://example.com:443/a/%62%7ec",
      "https://example.com/a/%62%7Ec",
    ].map { |source_url| described_class.call(connection_id: "astro-demo", source_url: source_url) }

    expect(variants.map(&:source_url).uniq).to eq(["https://example.com/a/b~c"])
    expect(variants.map(&:identity_digest).uniq.length).to eq(1)

    http = described_class.call(
      connection_id: "astro-demo",
      source_url: "http://example.com:80/a",
    )
    expect(http.source_url).to eq("http://example.com/a")
  end

  it "rejects trailing-dot hosts rather than creating another host identity" do
    expect do
      described_class.call(connection_id: "a", source_url: "https://example.com./a")
    end.to raise_error(ArgumentError, /trailing dot/)
  end

  it "rejects numeric and encoded host aliases outside the DNS-name contract" do
    [
      "https://127.0.0.1/a",
      "https://127.1/a",
      "https://0x7f000001/a",
      "https://0x7f.0.0.1/a",
      "https://0x7f.0x0.0x0.0x1/a",
      "https://127.0x0.0.1/a",
      "https://0x7f.1/a",
      "https://[::1]/a",
      "https://[0:0:0:0:0:0:0:1]/a",
      "https://%65xample.com/a",
    ].each do |source_url|
      expect do
        described_class.call(connection_id: "a", source_url: source_url)
      end.to raise_error(ArgumentError)
    end
  end

  it "accepts the deliberate ASCII DNS-name boundary" do
    maximum_label = "a" * DiscussionBridge::CanonicalSource::MAX_DNS_LABEL_BYTES
    maximum_host = [maximum_label, maximum_label, maximum_label, "a" * 61].join(".")
    accepted = [
      "https://localhost/a",
      "https://my-host.example/a",
      "https://examplex.example/a",
      "https://xn--bcher-kva.example/a",
      "https://#{maximum_label}.example/a",
      "https://#{maximum_host}/a",
    ]

    expect(accepted.map { |url| described_class.call(connection_id: "a", source_url: url) })
      .to all(be_a(described_class::Result))
  end

  it "rejects hosts outside the exact ASCII DNS-name grammar" do
    maximum_label = "a" * DiscussionBridge::CanonicalSource::MAX_DNS_LABEL_BYTES
    overlong_host = [maximum_label, maximum_label, maximum_label, "a" * 62].join(".")
    invalid = [
      "https://example..com/a",
      "https://-edge.example/a",
      "https://edge-.example/a",
      "https://under_score.example/a",
      "https://#{"a" * 64}.example/a",
      "https://#{overlong_host}/a",
      "https://[v1.fe]/a",
      "https://[fe80::1%25eth0]/a",
    ]

    invalid.each do |source_url|
      expect do
        described_class.call(connection_id: "a", source_url: source_url)
      end.to raise_error(ArgumentError)
    end
  end

  it "keeps nondefault ports and encoded reserved path octets distinct" do
    ordinary = described_class.call(connection_id: "a", source_url: "https://example.com/a:b")
    encoded = described_class.call(connection_id: "a", source_url: "https://example.com/a%3ab")
    nondefault = described_class.call(connection_id: "a", source_url: "https://example.com:444/a:b")

    expect(encoded.source_url).to eq("https://example.com/a%3Ab")
    expect([ordinary.identity_digest, encoded.identity_digest, nondefault.identity_digest].uniq.length).to eq(3)
  end

  it "rejects credentials, queries, fragments, and non-HTTP sources" do
    expect { described_class.call(connection_id: "a", source_url: "https://user@example.com/") }.to raise_error(ArgumentError)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/?token=secret") }.to raise_error(ArgumentError)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/#fragment") }.to raise_error(ArgumentError)
    expect { described_class.call(connection_id: "a", source_url: "file:///tmp/source") }.to raise_error(ArgumentError)
  end

  it "rejects ambiguous path separators instead of collapsing distinct resource identities" do
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/a//b") }
      .to raise_error(ArgumentError, /ambiguous separator/)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/a%2Fb") }
      .to raise_error(ArgumentError, /ambiguous separator/)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/a%5Cb") }
      .to raise_error(ArgumentError, /ambiguous separator/)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/a/../b") }
      .to raise_error(ArgumentError, /ambiguous separator/)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/a/%2e%2e/b") }
      .to raise_error(ArgumentError, /ambiguous separator/)
    %w[%252f %255c %252e%252e %252F %255C].each do |encoded|
      expect { described_class.call(connection_id: "a", source_url: "https://example.com/a/#{encoded}/b") }
        .to raise_error(ArgumentError, /ambiguous|encoded/)
    end
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/a/%0a/b") }
      .to raise_error(ArgumentError, /ambiguous/)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/a/%zz/b") }
      .to raise_error(ArgumentError, /percent encoding|absolute HTTP/)

    accepted = described_class.call(connection_id: "a", source_url: "https://example.com/a/b")
    expect(accepted.source_url).to eq("https://example.com/a/b")
  end

  it "bounds durable identity inputs" do
    expect { described_class.call(connection_id: "a" * 101, source_url: "https://example.com/") }.to raise_error(ArgumentError)
    expect { described_class.call(connection_id: "a", source_url: "https://example.com/#{"a" * 2048}") }.to raise_error(ArgumentError)
  end
end
