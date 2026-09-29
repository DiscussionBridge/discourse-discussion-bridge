# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::PublicationWorkProtocol do
  it "accepts bounded diagnostic prose but rejects lease and authorization-like secrets" do
    lease_token = "1" * 64
    expect(
      described_class.safe_error_detail!(
        "Destination returned a temporary unavailable response.",
        lease_token: lease_token,
      ),
    ).to eq("Destination returned a temporary unavailable response.")

    [
      "Failed with lease #{lease_token}",
      "Authorization: Bearer #{"a" * 40}",
      "X-DiscussionBridge-Secret=#{"b" * 40}",
      "Basic #{"c" * 40}",
    ].each do |detail|
      expect do
        described_class.safe_error_detail!(detail, lease_token: lease_token)
      end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) { |error|
        expect(error.error_code).to eq("validation_failed")
      }
    end
  end

  it "parses valid nanosecond UTC timestamps and rejects normalized calendar dates" do
    expect(described_class.parse_time!("2026-09-27T18:30:00.123456789Z").nsec).to eq(123_456_789)
    expect do
      described_class.parse_time!("2026-02-30T18:30:00Z")
    end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) { |error|
      expect(error.error_code).to eq("malformed_value")
    }
    expect do
      described_class.parse_time!("2026-09-27T24:00:00Z")
    end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) { |error|
      expect(error.error_code).to eq("malformed_value")
    }
  end
end
