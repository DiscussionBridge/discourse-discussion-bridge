# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::AdapterRequestBoundary do
  it "rejects duplicate keys at every object level instead of accepting the last one" do
    ['{"bridge_record":{},"bridge_record":{}}', '{"bridge_record":{"title":"one","title":"two"}}'].each do |wire|
      expect { described_class.parse(wire) }.to raise_error(described_class::Error) do |error|
        expect(error.error_code).to eq("invalid_json")
      end
    end
  end

  it "rejects oversized, deeply nested, malformed UTF-8 and nonfinite JSON" do
    wires = [nil, "", " " * 65_537, "[" * 65 + "0" + "]" * 65, "\xFF".b, '{"value":NaN}']
    wires.each { |wire| expect { described_class.parse(wire) }.to raise_error(described_class::Error) }
  end

  it "returns ordinary nested objects after lexical duplicate screening so safe copies do not report false duplicates" do
    value = described_class.parse('{"segments":[{"items":[{"id":"one"},{"id":"two"}]}]}')
    copy = value.deep_dup
    expect(copy).to eq(value)
    copy.fetch("segments").sole.fetch("items").first["id"] = "changed"
    expect(value.fetch("segments").sole.fetch("items").first.fetch("id")).to eq("one")
    expect { described_class.parse('{"items":[{"id":"one","id":"two"}]}') }.to raise_error(described_class::Error, /invalid_json/)
  end

  it "bounds every documented error without reflecting submitted secrets or content" do
    described_class::ERROR_STATUSES.each_key do |code|
      payload = described_class.error_payload(code, "correlation-1")
      expect(payload.keys).to contain_exactly(:error_code, :message, :correlation_id)
      expect(JSON.generate(payload).bytesize).to be <= 4096
      expect(payload[:error_code]).to eq(code)
    end
  end

  it "validates correlation as UTF-8 bytes even when Rack provides a binary string" do
    expect(described_class.valid_correlation?("bad-\xFF".b)).to eq(false)
    expect(described_class.valid_correlation?("attempt-\u00e9".b)).to eq(true)
  end
end

describe DiscussionBridge::BoundedAdapterBody do
  it "uses a safe error correlation rather than reflecting invalid header bytes" do
    downstream = ->(_env) { raise "Rails must not be called" }
    result = described_class.new(downstream).call(
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/discussion-bridge/v1/bridge-records/resolve.json",
      "HTTP_X_DISCUSSIONBRIDGE_CORRELATION" => "bad-\xFF".b,
    )
    expect(result[0]).to eq(422)
    body = JSON.parse(result[2].join)
    expect(body.fetch("error_code")).to eq("validation_failed")
    expect(body.fetch("correlation_id")).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "rejects an over-bound stream before calling Rails or parsing it, without an advertised length" do
    downstream = ->(_env) { raise "Rails must not be called" }
    input = StringIO.new(" " * 100_000)
    result = described_class.new(downstream).call(
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/discussion-bridge/v1/bridge-records/resolve.json",
      "CONTENT_TYPE" => "application/json", "HTTP_X_DISCUSSIONBRIDGE_CONTRACT" => "0.2.0-alpha.22",
      "HTTP_X_DISCUSSIONBRIDGE_CORRELATION" => "bounded-stream-1", "rack.input" => input,
    )
    expect(result[0]).to eq(413)
    expect(input.pos).to eq(65_537)
    expect(JSON.parse(result[2].join).fetch("error_code")).to eq("request_too_large")
  end

  it "leaves unrelated native forum requests and their input stream untouched" do
    input = StringIO.new("native forum request")
    downstream = ->(env) { [200, {}, [env.fetch("rack.input").read]] }
    response = described_class.new(downstream).call(
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/posts", "rack.input" => input,
    )
    expect(response).to eq([200, {}, ["native forum request"]])
  end
end
