# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsProtocol do
  it "does not round noninteger JSON values into accepted unsigned counters" do
    %w[
      1.00000000000000001
      9007199254740991.4
      1e-999
      -1e-999
      9007199254740992
      1e99999999
    ].each do |number|
      expect {
        described_class.parse_json("{\"offset\":#{number}}")
      }.to raise_error(described_class::Error) { |error|
        expect(error.code).to eq("invalid_field")
      }
    end
    %w[1 1.0 1e0 0.1e1 1000e-3 0e99999999].each do |number|
      expect(
        described_class.parse_json("{\"offset\":#{number}}").fetch("offset")
      ).to eq(number.start_with?("0e") ? 0 : 1)
    end
    expect(
      described_class.parse_json(
        '{"offset":1.00000000000000001}',
        reject_negative_zero: false
      )
    ).to be_a(Hash)
  end

  conformance =
    JSON.parse(
      File.read(File.join(__dir__, "../fixtures/cms_protocol_conformance.json"))
    )

  def positive(id)
    @conformance ||=
      JSON.parse(
        File.read(
          File.join(__dir__, "../fixtures/cms_protocol_conformance.json")
        )
      )
    @conformance
      .fetch("positive_examples")
      .find { |item| item.fetch("id") == id }
      .fetch("value")
      .deep_dup
  end

  def rejected(code, &block)
    expect(&block).to raise_error(
      DiscussionBridge::CmsProtocol::Error
    ) { |error| expect(error.code).to eq(code) }
  end

  it "rejects duplicate keys at any depth, BOM and invalid UTF-8" do
    rejected("invalid_json") do
      described_class.parse_json('{"a":{"x":1,"x":2}}')
    end
    rejected("invalid_json") { described_class.parse_json("\uFEFF{}") }
    rejected("invalid_json") do
      described_class.parse_json("{\"x\":\"\xff\"}".b)
    end
  end

  it "rejects negative zero without mistaking its occurrence in a string for a number" do
    %w[-0 -0.0 -0e10].each do |token|
      rejected("invalid_field") do
        described_class.parse_json("{\"x\":#{token}}")
      end
    end
    expect(described_class.parse_json('{"x":"-0","y":0}')["x"]).to eq("-0")
  end

  it "rejects trailing input, scalar bodies and oversized raw JSON" do
    rejected("invalid_json") { described_class.parse_json("{} {}") }
    rejected("invalid_json") { described_class.parse_json("[]") }
    rejected("body_too_large") { described_class.parse_json(" " * 65_537) }
  end

  it "requires valid exact millisecond Gregorian instants" do
    described_class.validate!("Instant", "2024-02-29T23:59:59.123Z")
    %w[
      2025-02-29T12:00:00.000Z
      2024-02-29T24:00:00.000Z
      2024-02-29T23:59:60.000Z
      2024-02-29T12:00:00Z
    ].each do |value|
      rejected("invalid_field") { described_class.validate!("Instant", value) }
    end
  end

  it "rejects unknown fields, absent required nullable fields and nil UUIDs" do
    rejected("unknown_field") do
      described_class.validate!(
        "Claim",
        { "mutation_id" => SecureRandom.uuid, "extra" => true }
      )
    end
    rejected("invalid_field") { described_class.validate!("Claim", {}) }
    rejected("invalid_field") do
      described_class.validate!("UUID", "00000000-0000-0000-0000-000000000000")
    end
  end

  it "counts decoded UTF-8 bytes and rejects unsafe canonical identifiers" do
    rejected("invalid_field") do
      described_class.validate!("OpaqueId", "é" * 128)
    end
    rejected("invalid_field") do
      described_class.validate!("OpaqueId", "x\u0085y")
    end
    rejected("invalid_field") do
      described_class.validate!("CoreId", "9223372036854775808")
    end
    described_class.validate!("CoreId", "9223372036854775807")
  end

  it "uses exact HTTPS collision keys without changing escaped path or query ordering" do
    expect(
      described_class.url_key("https://EXAMPLE.com:443/a%2fb?b=2&a=1")
    ).to eq("https://example.com/a%2fb?b=2&a=1")
    expect(described_class.url_key("https://example.com")).to eq(
      "https://example.com/"
    )
    %w[
      http://example.com/
      https://u:p@example.com/
      https://example.com/a#b
      https://example.com/%2e%2e/a
      https://example.com/%xx
    ].each do |url|
      rejected("invalid_field") { described_class.validate!("Url", url) }
    end
  end

  it "requires canonical thirty-two-byte secret lease tokens" do
    token = SecureRandom.urlsafe_base64(32, false)
    described_class.validate!("LeaseToken", token)
    rejected("invalid_field") do
      described_class.validate!("LeaseToken", token + "=")
    end
    rejected("invalid_field") do
      described_class.validate!("LeaseToken", "_" * 43)
    end
  end

  it "distinguishes withdrawal and publication closed result branches" do
    result = {
      "kind" => "withdraw",
      "native_id" => "entry",
      "external_id" => "post",
      "canonical_url" => "https://example.com/a",
      "native_revision" => nil,
      "ownership_receipt_sha256" => "a" * 64
    }
    described_class.validate!("SyncResult", result)
    rejected("unknown_field") do
      described_class.validate!(
        "SyncResult",
        result.merge("representation" => {})
      )
    end
  end

  it "binds immutable copied CMS grammar and frozen fixture provenance" do
    expect(described_class::SCHEMA_SHA256).to eq(
      "b5ce03ac60379a60e9adc3b4193b9f49e9f6c0687010a91a138577d4cbf95760"
    )
    expect(conformance.fetch("copied_schema_sha256")).to eq(
      described_class::SCHEMA_SHA256
    )
    expect(
      conformance
        .fetch("provenance")
        .fetch("v2_positive_examples")
        .fetch("sha256")
    ).to eq("dbb6fdb51cd75e3fe5f276582d293300f684e44e39cc84e29d7927485f145add")
    expect(
      conformance
        .fetch("provenance")
        .fetch("v2_negative_cases_and_runtime_plan")
        .fetch("sha256")
    ).to eq("c5f2bae11a90337541f74fe5ef10d87262cdc986551c6a40e0761d99a7d52b13")
    expect(described_class::SCHEMA.fetch("types").size).to eq(138)
    expect(described_class::SCHEMA.fetch("routes").size).to eq(32)
    expect(
      described_class::SCHEMA.fetch("types").keys.grep(/\ANetwork/)
    ).to be_empty
    expect(
      described_class::SCHEMA.fetch("types").fetch("Work").fetch("fields")
    ).to be_frozen
    expect(conformance.fetch("positive_examples").size).to eq(49)
    expect(conformance.fetch("type_cases").size).to eq(16)
    expect(conformance.fetch("raw_json_cases").size).to eq(2)
  end

  conformance
    .fetch("positive_examples")
    .each do |item|
      it "accepts unchanged frozen CMS positive #{item.fetch("id")}" do
        described_class.validate!(item.fetch("type"), item.fetch("value"))
        if item.fetch("value").is_a?(Hash)
          parsed =
            described_class.parse_json(
              JSON.generate(item.fetch("value")),
              type: item.fetch("type")
            )
          expect(described_class.semantic_identity(parsed)).to eq(
            described_class.semantic_identity(item.fetch("value"))
          )
        end
      end
    end

  conformance
    .fetch("type_cases")
    .each do |item|
      it "rejects unchanged frozen CMS negative #{item.fetch("id")}" do
        rejected(item.fetch("expected").fetch("code")) do
          described_class.validate!(item.fetch("type"), item.fetch("input"))
        end
      end
    end

  conformance
    .fetch("raw_json_cases")
    .each do |item|
      it "rejects unchanged frozen raw JSON #{item.fetch("id")}" do
        rejected(item.fetch("expected").fetch("code")) do
          described_class.parse_json(item.fetch("raw"))
        end
      end
    end

  it "validates syntax before numeric semantics and defers them only in syntax-only mode" do
    rejected("invalid_json") { described_class.parse_json('{"x":-0} trailing') }
    rejected("invalid_json") { described_class.parse_json('{"x":-0,}') }
    value =
      described_class.parse_json('{"x":-1e-999}', reject_negative_zero: false)
    expect(value).to be_a(Hash)
    rejected("invalid_field") { described_class.parse_json('{"x":-1e-999}') }
    rejected("invalid_field") do
      described_class.validate!("UInt", value.fetch("x"))
    end
    rejected("invalid_json") do
      described_class.parse_json('{"x":{"a":1,"\\u0061":2}}')
    end
  end

  it "separates syntax-only preauthentication from raw negativezero typed rejection" do
    raw = '{"x":-0,"y":-0.0,"z":-0e10}'
    expect(
      described_class.parse_json(raw, reject_negative_zero: false)
    ).to be_a(Hash)
    rejected("invalid_field") { described_class.parse_json(raw) }
    rejected("invalid_json") do
      described_class.parse_json(
        '{"x":-0} trailing',
        reject_negative_zero: false
      )
    end
    rejected("invalid_json") do
      described_class.parse_json('{"x":1,"x":2}', reject_negative_zero: false)
    end
    rejected("invalid_json") do
      described_class.parse_json("0", reject_negative_zero: false)
    end
    rejected("invalid_json") do
      described_class.parse_json("[]", reject_negative_zero: false)
    end
    rejected("invalid_json") do
      described_class.parse_json("\uFEFF{}", reject_negative_zero: false)
    end
    rejected("body_too_large") do
      described_class.parse_json(" " * 65_537, reject_negative_zero: false)
    end
  end

  it "uses proleptic Gregorian dates and actual UTF8 bytes" do
    described_class.validate!("Instant", "1600-02-29T00:00:00.000Z")
    rejected("invalid_field") do
      described_class.validate!("Instant", "1500-02-29T00:00:00.000Z")
    end
    rejected("invalid_field") do
      described_class.validate!("OpaqueId", "\xff".b)
    end
  end

  it "keeps exact numeric provenance through declared typed field traversal" do
    %w[1.00000000000000001 9007199254740991.4 1e-999 -0].each do |token|
      raw = "{\"offset\":#{token}}"
      rejected("invalid_field") do
        described_class.parse_json(raw, type: "ContentQuery")
      end
      parsed = described_class.parse_json(raw, reject_negative_zero: false)
      rejected("invalid_field") do
        described_class.validate!("ContentQuery", parsed)
      end
    end
    rejected("unknown_field") do
      described_class.parse_json('{"unknown":1e-999}', type: "ContentQuery")
    end
    expect(
      described_class.parse_json('{"offset":0.1e1}', type: "ContentQuery")
    ).to eq("offset" => 1)
    rejected("invalid_field") do
      described_class.semantic_identity(
        described_class.parse_json(
          '{"offset":1e-999}',
          reject_negative_zero: false
        )
      )
    end
  end

  it "binds numeric lexemes through nested objects, arrays and escaped keys without reading string content as numbers" do
    raw =
      '{"\u006fffset":1.0,"text":"-0 { \"value\" : 1e-999 }","items":[{"n":0.1e1},null,true]}'
    expect(described_class.parse_json(raw)).to eq(
      "offset" => 1,
      "text" => '-0 { "value" : 1e-999 }',
      "items" => [{ "n" => 1 }, nil, true]
    )
    raw = '{"offset":1,"nested":[{"n":1.00000000000000001}]}'
    rejected("invalid_field") { described_class.parse_json(raw) }
  end

  it "preserves source chronology, unique authors and exact primary author mapping" do
    source = positive("initial_feed").fetch("items").first.fetch("source")
    source["source_updated_at"] = "2020-01-01T00:00:00.000Z"
    rejected("invalid_field") { described_class.validate!("Source", source) }
    source["source_updated_at"] = nil
    described_class.validate!("Source", source)
    authors = [
      { "id" => "one", "name" => "First" },
      { "id" => "one", "name" => "Second" }
    ]
    rejected("invalid_field") do
      described_class.validate!("SourceAuthors", authors)
    end
    input = positive("to_resolve")
    input.fetch("bridge_record")["primary_source_author_id"] = "absent"
    rejected("invalid_field") { described_class.validate!("ToResolve", input) }
  end

  it "requires action-matching source revision, attempt ceiling and lease generation" do
    lease = positive("lease")
    lease.fetch("work")["attempt"] = 4
    rejected("invalid_field") { described_class.validate!("Lease", lease) }
    lease.fetch("work")["attempt"] = 1
    lease.fetch("work")["source_revision"] = nil
    rejected("invalid_field") { described_class.validate!("Lease", lease) }
    lease.fetch("work")["action"] = "withdraw"
    described_class.validate!("Lease", lease)
    lease["lease_generation"] += 1
    rejected("invalid_field") { described_class.validate!("Lease", lease) }
  end

  it "requires receiver-derived transient errors and bounded retry delays" do
    error = positive("error")
    error["retryable"] = true
    rejected("invalid_field") { described_class.validate!("Error", error) }
    error["code"] = "rate_limited"
    error["retry_after_seconds"] = 0
    rejected("invalid_field") { described_class.validate!("Error", error) }
    error["retry_after_seconds"] = 3_601
    rejected("invalid_field") { described_class.validate!("Error", error) }
    error["retry_after_seconds"] = 3_600
    described_class.validate!("Error", error)
    failure = positive("failure")
    failure["code"] = "public_verification_failed"
    failure["retry_after_seconds"] = 30
    rejected("invalid_field") { described_class.validate!("Failure", failure) }
  end

  it "requires adjacent byte chunks while permitting a splitUTF8 character and empty end" do
    chunk =
      positive("content_chunk").merge(
        "content_bytes" => 4,
        "offset" => 0,
        "next_offset" => 2,
        "content_base64" => Base64.strict_encode64([0xf0, 0x9f].pack("C*"))
      )
    described_class.validate!("ContentChunk", chunk)
    chunk["next_offset"] = nil
    rejected("invalid_field") do
      described_class.validate!("ContentChunk", chunk)
    end
    chunk.merge!("offset" => 4, "content_base64" => "")
    described_class.validate!("ContentChunk", chunk)
    chunk["offset"] = 5
    rejected("invalid_field") do
      described_class.validate!("ContentChunk", chunk)
    end
  end

  it "requires full hashes and exact bounded-excerpt metadata without universal native caps" do
    record = positive("to_resolve").fetch("bridge_record")
    record["source_content_sha256"] = "0" * 64
    rejected("content_hash_mismatch") do
      described_class.validate!("ToRecord", record)
    end
    record["representation"] = {
      "kind" => "bounded_excerpt",
      "read_more_url" => record.fetch("canonical_url")
    }
    record["source_content_bytes"] = 49_153
    described_class.validate!("ToRecord", record)
    record["source_content_bytes"] = 49_152
    rejected("invalid_field") { described_class.validate!("ToRecord", record) }
    record["source_content_bytes"] = 49_153
    record.fetch("representation")[
      "read_more_url"
    ] = "https://publisher.example/wrong/"
    rejected("invalid_field") { described_class.validate!("ToRecord", record) }
  end

  it "applies defaults only after validating omission versus explicit null" do
    original = {}
    expect(described_class.apply_defaults("ContentQuery", original)).to eq(
      "offset" => 0
    )
    expect(original).to eq({})
    rejected("invalid_field") do
      described_class.apply_defaults("ContentQuery", { "offset" => nil })
    end
    input = positive("to_resolve")
    described_class.validate!("ToResolve", input)
    expect(input.fetch("bridge_record")).not_to have_key("visibility")
    expect(
      described_class
        .apply_defaults("ToResolve", input)
        .fetch("bridge_record")
        .fetch("visibility")
    ).to eq("unlisted")
  end

  it "preserves policy selection and feed checkpoint shape" do
    policy = positive("policy")
    policy["include_topic_ids"] = ["9"]
    policy["exclude_topic_ids"] = ["9"]
    rejected("invalid_field") { described_class.validate!("Policy", policy) }
    feed = positive("initial_feed")
    feed["next_cursor"] = "next"
    feed["checkpoint_cursor"] = "checkpoint"
    rejected("invalid_field") { described_class.validate!("SourceFeed", feed) }
    rejected("invalid_field") do
      described_class.validate!("SourceFeedQuery", { "stream" => "changes" })
    end
  end

  it "keeps public proof hashes and protected reconciliation fields exact" do
    verification = positive("verify_ack").fetch("verification")
    verification.fetch("representation")["source_content_sha256"] = "0" * 64
    rejected("invalid_field") do
      described_class.validate!("PublishedVerification", verification)
    end
    result = positive("resolve_created")
    result["outcome"] = "reconciliation_required"
    rejected("invalid_field") do
      described_class.validate!("ResolveResult", result)
    end
    move = positive("source_url_move_finalize")
    move["new_source_revision"] = move.fetch("expected_source_revision")
    rejected("invalid_field") do
      described_class.validate!("SourceUrlMoveFinalize", move)
    end
  end

  it "canonicalizes semantic member order and integer spelling without changing strings or arrays" do
    expect(described_class.semantic_identity({ "a" => 1, "b" => 2 })).to eq(
      described_class.semantic_identity({ "b" => 2, "a" => 1.0 })
    )
    expect(described_class.semantic_identity({})).not_to eq(
      described_class.semantic_identity({ "a" => nil })
    )
    expect(described_class.semantic_identity([1, 2])).not_to eq(
      described_class.semantic_identity([2, 1])
    )
    expect(described_class.semantic_identity("é")).not_to eq(
      described_class.semantic_identity("e\u0301")
    )
  end

  it "matches independent ownership vectors with canonical numeric text and no secret field" do
    receipt = positive("native_ownership_receipt")
    expect(described_class.ownership_hash(receipt)).to eq(
      "ef9ae2df5fa27e2ba912358f727d7031a34cbac6914cdb99b38b3a88754801e1"
    )
    receipt["last_lease_generation"] = receipt.fetch(
      "last_lease_generation"
    ).to_f
    expect(described_class.ownership_hash(receipt)).to eq(
      "ef9ae2df5fa27e2ba912358f727d7031a34cbac6914cdb99b38b3a88754801e1"
    )
    receipt["lease_token"] = "forbidden-secret"
    rejected("unknown_field") { described_class.ownership_hash(receipt) }
  end
end
