# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge comments-only fullInteractive redirect" do
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic) }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_comments_only_full_interactive = true
    SiteSetting.embed_full_app = true
    SiteSetting.embed_full_app_signin_flow = true
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

    location = URI.parse(response.location)
    query = Rack::Utils.parse_nested_query(location.query)
    expect(location.path).to eq(URI.parse(topic.url).path)
    expect(query).to include(
      "embed_mode" => "true",
      "class_name" => "discussion-bridge-comments-only",
    )
    expect(query["discussion_bridge_embed_token"]).to be_present

    follow_redirect!
    expect(response.body).to match(
      /<html[^>]+class="[^"]*discussion-bridge-comments-only[^"]*"/,
    )
    expect(response.body).to include(
      %(<meta name="discussion-bridge-completed-mapping" content="#{topic.id}">),
    )
  end

  it "does not attest a forged direct topic URL" do
    get topic.url,
        params: {
          embed_mode: "true",
          class_name: "discussion-bridge-comments-only",
          discussion_bridge_embed_token: "forged",
        }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('meta name="discussion-bridge-completed-mapping"')
  end

  it "does not attest an ordinary topic with another mapping's valid token" do
    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
    token = Rack::Utils.parse_nested_query(URI.parse(response.location).query).fetch(
      "discussion_bridge_embed_token",
    )
    ordinary_topic = Fabricate(:topic)
    Fabricate(:post, topic: ordinary_topic)

    get ordinary_topic.url,
        params: {
          embed_mode: "true",
          class_name: "discussion-bridge-comments-only",
          discussion_bridge_embed_token: token,
        }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('meta name="discussion-bridge-completed-mapping"')
  end

  it "does not attest a mapping that became incomplete after redirect issuance" do
    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
    location = response.location
    DiscussionBridgeConnection.update_all(state: "failed")

    get location

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('meta name="discussion-bridge-completed-mapping"')
  end

  it "fails closed instead of serving the legacy handoff embed when Core full-app embedding is off" do
    SiteSetting.embed_full_app = false

    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include("Embed full app setting is disabled")
    expect(response.body).not_to include("Continue Discussion")
  end

  it "does not block an ordinary Core embed when the topic is not a completed mapping" do
    DiscussionBridgeConnection.update_all(state: "failed")
    SiteSetting.embed_full_app = false

    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("fullInteractive is unavailable")
  end

  it "preserves a valid operator class and appends the comments-only class" do
    get "/embed/comments",
        params: { topic_id: topic.id, full_app: "true", class_name: "operator-theme" }

    location = URI.parse(response.location)
    query = Rack::Utils.parse_nested_query(location.query)
    expect(location.path).to eq(URI.parse(topic.url).path)
    expect(query["class_name"]).to eq("operator-theme discussion-bridge-comments-only")
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
