# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::AdapterRequestBoundary do
  it "implements the released Alpha.21 common constants and bounded error envelope" do
    expect(described_class::CONTRACT_VERSION).to eq("0.2.0-alpha.21")
    expect(described_class::CONNECTION_HEADER).to eq("X-DiscussionBridge-Connection")
    expect(described_class::SECRET_HEADER).to eq("X-DiscussionBridge-Secret")
    expect(described_class::CONTRACT_HEADER).to eq("X-DiscussionBridge-Contract")
    expect(described_class::CORRELATION_HEADER).to eq("X-DiscussionBridge-Correlation")
    expect(described_class::CONNECTION_ID_PATTERN).to match("dbc_111111111111111111111111")
    expect(described_class::CONNECTION_ID_PATTERN).not_to match("dbc_gggggggggggggggggggggggg")
    expect(described_class::MAX_CORRELATION_BYTES).to eq(200)
    expect(described_class::MAX_ERROR_JSON_BYTES).to eq(4096)

    described_class::ERROR_STATUSES.each_key do |error_code|
      payload = described_class.error_payload(error_code, "request-1")
      expect(payload.keys).to contain_exactly(:error_code, :message, :correlation_id)
      expect(JSON.generate(payload).bytesize).to be <= 4096
      expect(payload.to_json).not_to include("fixture-secret")
    end
  end

  it "accepts only bounded nonblank correlation identifiers without control bytes" do
    expect(described_class.valid_correlation?("request-1")).to eq(true)
    expect(described_class.valid_correlation?("request/1")).to eq(true)
    expect(described_class.valid_correlation?(" ")).to eq(false)
    expect(described_class.valid_correlation?("a" * 201)).to eq(false)
    expect(described_class.valid_correlation?("request\n1")).to eq(false)
  end
end
