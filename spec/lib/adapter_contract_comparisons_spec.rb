# frozen_string_literal: true

require "rails_helper"
require_relative "../../script/adapter_contract_comparisons"

describe DiscussionBridge::AdapterContractComparisons do
  let(:released) do
    {
      authentication: {
        "connection_header" => "X-DiscussionBridge-Connection",
        "secret_header" => "X-DiscussionBridge-Secret",
        "contract_header" => "X-DiscussionBridge-Contract",
        "contract_header_value" => "0.2.0-alpha.21",
      },
      common: {
        "correlation_header" => "X-DiscussionBridge-Correlation",
        "correlation_id_maximum_bytes" => 200,
      },
      errors: { "maximum_json_bytes" => 4096 },
    }
  end

  let(:matching_values) do
    {
      CONNECTION_HEADER: "X-DiscussionBridge-Connection",
      SECRET_HEADER: "X-DiscussionBridge-Secret",
      CONTRACT_HEADER: "X-DiscussionBridge-Contract",
      CONTRACT_VERSION: "0.2.0-alpha.21",
      CORRELATION_HEADER: "X-DiscussionBridge-Correlation",
      MAX_CORRELATION_BYTES: 200,
      MAX_ERROR_JSON_BYTES: 4096,
    }
  end

  def boundary_with(overrides = {})
    Module.new.tap do |boundary|
      matching_values.merge(overrides).each do |name, value|
        boundary.const_set(name, value)
      end
    end
  end

  def verify(boundary)
    described_class.verify_common_boundary!(
      boundary: boundary,
      authentication: released.fetch(:authentication),
      common: released.fetch(:common),
      errors: released.fetch(:errors),
    )
  end

  it "retains an earlier integer mismatch when a later matching comparison has the same actual value" do
    boundary = boundary_with(MAX_CORRELATION_BYTES: 4096)

    expect { verify(boundary) }.to raise_error(
      described_class::Mismatch,
      "released Adapter Protocol mismatch for MAX_CORRELATION_BYTES: 4096 != 200",
    )
  end

  it "retains an earlier string mismatch when a later matching comparison has the same actual value" do
    boundary = boundary_with(CONNECTION_HEADER: "X-DiscussionBridge-Secret")

    expect { verify(boundary) }.to raise_error(
      described_class::Mismatch,
      'released Adapter Protocol mismatch for CONNECTION_HEADER: ' \
        '"X-DiscussionBridge-Secret" != "X-DiscussionBridge-Connection"',
    )
  end

  it "checks every independently labeled common-boundary value" do
    mismatches = {
      CONNECTION_HEADER: "wrong-connection",
      SECRET_HEADER: "wrong-secret",
      CONTRACT_HEADER: "wrong-contract",
      CONTRACT_VERSION: "wrong-version",
      CORRELATION_HEADER: "wrong-correlation",
      MAX_CORRELATION_BYTES: 201,
      MAX_ERROR_JSON_BYTES: 4097,
    }

    mismatches.each do |name, value|
      expect { verify(boundary_with(name => value)) }.to raise_error(
        described_class::Mismatch,
        /mismatch for #{name}:/,
      )
    end
  end

  it "accepts the complete matching common boundary" do
    expect(verify(boundary_with)).to eq(true)
  end
end
