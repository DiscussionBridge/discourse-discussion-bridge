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
    expect(query["discussion_bridge_embed_token"]).to start_with("#{topic.id}.")
    expect(
      DiscussionBridge::EmbedRouteAttestation.verify(
        query["discussion_bridge_embed_token"],
      )[:mapping].topic_id,
    ).to eq(topic.id)

    follow_redirect!
    expect(response.body).to match(
      /<html[^>]+class="[^"]*discussion-bridge-comments-only[^"]*"/,
    )
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
    attestation =
      DiscussionBridge::EmbedRouteAttestation.verify(query["discussion_bridge_embed_token"])
    expect(attestation[:class_name]).to eq("operator-theme discussion-bridge-comments-only")
  end

  it "restores only a currently completed attested mapping" do
    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
    token = Rack::Utils.parse_nested_query(URI.parse(response.location).query).fetch(
      "discussion_bridge_embed_token",
    )

    get "/discussion-bridge/embed/restore", params: { token: token }
    expect(response).to have_http_status(:redirect)
    restored = URI.parse(response.location)
    expect(restored.path).to eq(URI.parse(topic.url).path)
    expect(Rack::Utils.parse_nested_query(restored.query)).to include(
      "embed_mode" => "true",
      "class_name" => "discussion-bridge-comments-only",
      "discussion_bridge_embed_token" => token,
    )

    SiteSetting.embed_full_app = false
    get "/discussion-bridge/embed/restore", params: { token: token }
    expect(response).to have_http_status(:not_found)
    SiteSetting.embed_full_app = true

    SiteSetting.embed_full_app_signin_flow = false
    get "/discussion-bridge/embed/restore", params: { token: token }
    expect(response).to have_http_status(:not_found)
    SiteSetting.embed_full_app_signin_flow = true

    DiscussionBridgeConnection.update_all(state: "failed")
    get "/discussion-bridge/embed/restore", params: { token: token }
    expect(response).to have_http_status(:not_found)
  end

  it "rejects forged, malformed, and topic-mismatched attestations" do
    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
    token = Rack::Utils.parse_nested_query(URI.parse(response.location).query).fetch(
      "discussion_bridge_embed_token",
    )

    [
      "#{topic.id}.forged-marker-without-a-server-signature",
      "not-a-topic-route-token",
      token.sub(/\A#{topic.id}\./, "#{topic.id + 1}."),
    ].each do |invalid_token|
      get "/discussion-bridge/embed/restore", params: { token: invalid_token }
      expect(response).to have_http_status(:not_found)
    end

    mapping = DiscussionBridgeConnection.find_by!(topic_id: topic.id, state: "complete")
    same_second_usec = mapping.updated_at.usec == 123_456 ? 654_321 : 123_456
    same_second_update = mapping.updated_at.change(usec: same_second_usec)
    expect(same_second_update.to_i).to eq(mapping.updated_at.to_i)
    expect(same_second_update).not_to eq(mapping.updated_at)
    mapping.update_column(:updated_at, same_second_update)
    expect(DiscussionBridge::EmbedRouteAttestation.verify(token)).to be_nil
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
