# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge do
  it "is disabled and inert by default" do
    expect(SiteSetting.discussion_bridge_enabled).to eq(false)
    expect(SiteSetting.discussion_bridge_endpoint_enabled).to eq(false)
    expect(SiteSetting.discussion_bridge_default_visibility).to eq("unlisted")
  end

  it "uses the settled DiscussionBridge brand in every site-setting label" do
    settings = %i[
      discussion_bridge_enabled
      discussion_bridge_endpoint_enabled
      discussion_bridge_service_username
      discussion_bridge_effective_category_id
      discussion_bridge_effective_tags
      discussion_bridge_lane_policies
      discussion_bridge_default_visibility
      discussion_bridge_comments_only_full_interactive
    ]

    labels = settings.map { |setting| SiteSettings::LabelFormatter.humanized_name(setting) }

    expect(labels).to all(start_with("DiscussionBridge "))
    expect(labels).to include("DiscussionBridge service username")
    expect(labels).not_to include(a_string_starting_with("Discussion bridge "))
  end

  it "uses the settled DiscussionBridge brand for the admin plugin title" do
    locale = File.read(
      File.expand_path("../config/locales/client.en.yml", __dir__),
      encoding: "UTF-8",
    )

    expect(locale).to include('discourse_discussion_bridge: "DiscussionBridge"')
  end
end
