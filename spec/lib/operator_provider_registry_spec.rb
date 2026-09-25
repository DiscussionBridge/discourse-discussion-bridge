# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperatorProviderRegistry do
  it "publishes one available first-party provider and a separate planned partner program" do
    catalog = described_class.public_catalog(selected_provider_id: "discussionbridge")

    expect(catalog).to contain_exactly(
      include(
        id: "discussionbridge",
        display_name: "DiscussionBridge Operator Service",
        organization_name: "DiscussionBridge / WebSynergetics",
        availability: "available",
        available: true,
        selected: true,
      ),
    )
    expect(described_class::PARTNER_PROGRAM).to include(
      display_name: "Approved Operator Partners",
      availability: "planned",
    )
  end

  it "allows operator email identities only in the selected provider registry domain" do
    expect(
      described_class.operator_email_allowed?(
        provider_id: "discussionbridge",
        email: "operator@discussionbridge.dev",
      ),
    ).to eq(true)
    expect(
      described_class.operator_email_allowed?(
        provider_id: "discussionbridge",
        email: "operator@example.com",
      ),
    ).to eq(false)
  end
end
