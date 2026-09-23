# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridgePublicationOverride do
  fab!(:admin)
  fab!(:topic)
  fab!(:connection) do
    DiscussionBridgeContentConnection.issue!(
      name: "WordPress publication",
      platform: "wordpress",
      allowed_origins: ["https://wordpress.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    ).first
  end

  it "stores one bounded decision per topic and connection" do
    described_class.create!(
      content_connection: connection,
      topic: topic,
      set_by: admin,
      decision: "exclude",
    )

    duplicate = described_class.new(
      content_connection: connection,
      topic: topic,
      set_by: admin,
      decision: "publish",
    )
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:topic_id]).to be_present
  end

  it "rejects an unknown decision" do
    override = described_class.new(
      content_connection: connection,
      topic: topic,
      set_by: admin,
      decision: "sync",
    )

    expect(override).not_to be_valid
    expect(override.errors[:decision]).to be_present
  end
end
