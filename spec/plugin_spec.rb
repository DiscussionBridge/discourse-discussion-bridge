# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge do
  it "is disabled and inert by default" do
    expect(SiteSetting.discussion_bridge_enabled).to eq(false)
    expect(SiteSetting.discussion_bridge_endpoint_enabled).to eq(false)
    expect(SiteSetting.discussion_bridge_core_zero_touch_compatibility).to eq(false)
    expect(SiteSetting.discussion_bridge_default_visibility).to eq("unlisted")
  end
end
