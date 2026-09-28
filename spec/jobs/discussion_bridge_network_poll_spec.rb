# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscussionBridgeNetworkPoll do
  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
  end

  it "performs no network work before explicit forum identity enablement" do
    allow(DiscussionBridge::NetworkWorker).to receive(:call)

    described_class.new.execute({})

    expect(DiscussionBridge::NetworkWorker).not_to have_received(:call)
    expect(DiscussionBridgeForumIdentity.current).to be_nil
  end
end
