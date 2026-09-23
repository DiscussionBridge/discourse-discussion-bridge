# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::PublicationSummary do
  fab!(:admin)
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @first, = DiscussionBridgeContentConnection.issue!(
      name: "First platform",
      platform: "astro",
      allowed_origins: ["https://first.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    )
    @second, = DiscussionBridgeContentConnection.issue!(
      name: "Second platform",
      platform: "wordpress",
      allowed_origins: ["https://second.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    )
    @first.update!(forum_publication_enabled: true)
    @second.update!(forum_publication_enabled: true)
  end

  def publication(connection:, host:, state:, action: "publish")
    result = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: connection.id,
      topic_id: topic.id,
      external_id: "topic-#{connection.id}",
      canonical_url: "https://#{host}/topic-#{connection.id}/",
      native_materialization: true,
    )
    result.record.update!(destination_state: state == "current" ? "healthy" : "pending")
    DiscussionBridgePublicationWorkItem.create!(
      content_connection: connection,
      bridge_record: result.record,
      topic_id: topic.id,
      action: action,
      state: state,
    )
  end

  it "summarizes publication across every enabled publishing connection" do
    publication(connection: @first, host: "first.example.com", state: "current")

    expect(described_class.call(topic.reload)).to eq(
      state: "partial",
      published: 1,
      total: 2,
      pending: 0,
      attention: 0,
    )

    publication(connection: @second, host: "second.example.com", state: "queued")
    expect(described_class.call(topic.reload)).to include(
      state: "pending",
      published: 1,
      total: 2,
      pending: 1,
      attention: 0,
    )

    DiscussionBridgePublicationWorkItem.find_by!(content_connection: @second, topic_id: topic.id)
      .update!(state: "failed")
    expect(described_class.call(topic.reload)).to include(state: "attention", attention: 1)
  end

  it "reflects connection eligibility changes made between summaries" do
    expect(described_class.call(topic)).to include(state: "not_published", total: 2)

    @second.update!(forum_publication_enabled: false)

    expect(described_class.call(topic)).to include(state: "not_published", total: 1)
  end

  it "supports administrator-only, staff, and configured-group badge audiences" do
    moderator = Fabricate(:moderator)
    editors = Fabricate(:group)
    editors.add(user)

    SiteSetting.discussion_bridge_publication_status_audience = "admins"
    expect(DiscussionBridge::PublicationStatusAccess.allowed?(admin)).to eq(true)
    expect(DiscussionBridge::PublicationStatusAccess.allowed?(moderator)).to eq(false)

    SiteSetting.discussion_bridge_publication_status_audience = "staff"
    expect(DiscussionBridge::PublicationStatusAccess.allowed?(moderator)).to eq(true)
    expect(DiscussionBridge::PublicationStatusAccess.allowed?(user)).to eq(false)

    SiteSetting.discussion_bridge_publication_status_audience = "groups"
    SiteSetting.discussion_bridge_publication_status_groups = editors.id.to_s
    expect(DiscussionBridge::PublicationStatusAccess.allowed?(admin)).to eq(true)
    expect(DiscussionBridge::PublicationStatusAccess.allowed?(user)).to eq(true)
    expect(DiscussionBridge::PublicationStatusAccess.allowed?(moderator)).to eq(false)
    expect(DiscussionBridge::PublicationStatusAccess.allowed?(nil)).to eq(false)
  end
end
