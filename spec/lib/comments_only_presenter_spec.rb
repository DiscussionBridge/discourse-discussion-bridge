# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CommentsOnlyPresenter do
  fab!(:topic)
  fab!(:mapping) do
    DiscussionBridgeConnection.create!(
      connection_id: "astro",
      canonical_source_url: "https://example.com/article",
      source_identity_digest: Digest::SHA256.hexdigest("astro\nhttps://example.com/article"),
      state: "complete",
      topic_id: topic.id,
      effective_actor_id: topic.user_id,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
    )
  end

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_comments_only_full_interactive = true
    SiteSetting.embed_full_app = true
    SiteSetting.embed_full_app_signin_flow = true
  end

  it "marks a completed mapped topic only in full-app embed mode" do
    expect(described_class.class_name(topic_id: topic.id, embed_mode: true)).to eq(
      "discussion-bridge-comments-only",
    )
    expect(described_class.class_name(topic_id: topic.id, embed_mode: false)).to be_nil
  end

  it "does not mark ordinary or incomplete topics" do
    ordinary_topic = Fabricate(:topic)
    mapping.update!(state: "failed", topic_id: nil)

    expect(described_class.class_name(topic_id: ordinary_topic.id, embed_mode: true)).to be_nil
    expect(described_class.class_name(topic_id: topic.id, embed_mode: true)).to be_nil
  end

  it "does not hide the first post of a From Discourse publication" do
    source_topic = Fabricate(:topic)
    DiscussionBridgeBridgeRecord.create!(
      resource_id: SecureRandom.uuid,
      direction: "from_discourse",
      state: "healthy",
      title: source_topic.title,
      topic_id: source_topic.id,
      effective_actor_id: source_topic.user_id,
      requested_visibility: "listed",
      effective_visibility: "listed",
    )

    expect(described_class.class_name(topic_id: source_topic.id, embed_mode: true)).to be_nil
  end

  it "is independently operator-disabled" do
    SiteSetting.discussion_bridge_comments_only_full_interactive = false

    expect(described_class.class_name(topic_id: topic.id, embed_mode: true)).to be_nil
  end

  it "reserves the comments-only class and preserves other valid operator classes" do
    expect(
      described_class.redirect_class_name(
        topic_id: topic.id,
        full_app: true,
        existing_class_name: "operator-theme discussion-bridge-comments-only",
      ),
    ).to eq("operator-theme discussion-bridge-comments-only")

    SiteSetting.discussion_bridge_comments_only_full_interactive = false

    expect(
      described_class.redirect_class_name(
        topic_id: topic.id,
        full_app: true,
        existing_class_name: "operator-theme discussion-bridge-comments-only",
      ),
    ).to eq("operator-theme")
    expect(
      described_class.redirect_class_name(
        topic_id: topic.id,
        full_app: true,
        existing_class_name: "discussion-bridge-comments-only",
      ),
    ).to be_nil
    expect(
      described_class.redirect_class_name(
        topic_id: topic.id,
        full_app: true,
        existing_class_name: "discussion-bridge-comments-only <bad",
      ),
    ).to be_nil
  end
end
