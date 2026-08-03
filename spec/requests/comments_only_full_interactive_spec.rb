# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge comments-only fullInteractive redirect" do
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic) }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_comments_only_full_interactive = true
    SiteSetting.embed_full_app = true
    SiteSetting.embed_any_origin = true
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

  it "adds the comments-only class through the Core full-app redirect" do
    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }

    expect(response).to redirect_to(
      "#{topic.url}?#{
        { embed_mode: true, class_name: "discussion-bridge-comments-only" }.to_query
      }",
    )

    follow_redirect!
    expect(response.body).to match(
      /<html[^>]+class="[^"]*discussion-bridge-comments-only[^"]*"/,
    )
  end

  it "preserves a valid operator class and appends the comments-only class" do
    get "/embed/comments",
        params: { topic_id: topic.id, full_app: "true", class_name: "operator-theme" }

    expect(response).to redirect_to(
      "#{topic.url}?#{
        { embed_mode: true, class_name: "operator-theme discussion-bridge-comments-only" }.to_query
      }",
    )
  end

  it "does not add the class for ordinary, incomplete, or disabled mappings" do
    DiscussionBridgeConnection.update_all(state: "failed")
    get "/embed/comments",
        params: {
          topic_id: topic.id,
          full_app: "true",
          class_name: "discussion-bridge-comments-only",
        }
    expect(response).to redirect_to("#{topic.url}?embed_mode=true")

    SiteSetting.discussion_bridge_comments_only_full_interactive = false
    DiscussionBridgeConnection.update_all(state: "complete")
    get "/embed/comments",
        params: {
          topic_id: topic.id,
          full_app: "true",
          class_name: "discussion-bridge-comments-only <bad",
        }
    expect(response).to redirect_to("#{topic.url}?embed_mode=true")
  end
end
