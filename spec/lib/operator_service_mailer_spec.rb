# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperatorServiceMailer do
  fab!(:admin)

  it "routes enrollment events to the selected registry provider without protected forum data" do
    service = DiscussionBridgeOperatorService.instance
    message = described_class.service_event(
      service: service,
      event: "requested",
      requested_by: admin,
    )
    body = message.body.decoded

    expect(message.to).to eq(["servicerequest@discussionbridge.dev"])
    expect(body).to include(
      "Provider ID: discussionbridge",
      "Provider: DiscussionBridge Operator Service",
      "Installation ID: #{service.installation_id}",
      "Enrollment ID: #{service.enrollment_id}",
    )
    expect(body).to include("contains no forum credentials")
    expect(body).not_to include("Content Connection secret:")
  end
end
