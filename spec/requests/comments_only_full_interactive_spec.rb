# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge comments-only fullInteractive redirect" do
  fab!(:service_actor, :admin)
  fab!(:topic) { Fabricate(:topic, user: service_actor) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  before do
    topic.update!(visible: false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_comments_only_full_interactive = true
    SiteSetting.embed_full_app = true
    SiteSetting.embed_full_app_signin_flow = true
    SiteSetting.embed_any_origin = true
    SiteSetting.discussion_bridge_service_username = service_actor.username
    SiteSetting.discussion_bridge_effective_category_id = topic.category_id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
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

  it "fails closed when a mapping becomes incomplete after redirect issuance" do
    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
    location = response.location
    DiscussionBridgeConnection.update_all(state: "failed")

    get location

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include('meta name="discussion-bridge-completed-mapping"')
  end

  it "fails closed instead of serving the legacy handoff embed when Core full-app embedding is off" do
    SiteSetting.embed_full_app = false

    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include("embed_full_app_disabled")
    expect(response.body).not_to include("Continue Discussion")
  end

  it "fails closed when Core sign-in flow or Bridge readiness is disabled" do
    {
      embed_full_app_signin_flow: "embed_full_app_signin_flow_disabled",
      discussion_bridge_comments_only_full_interactive: "comments_only_full_interactive_disabled",
      discussion_bridge_enabled: "plugin_disabled",
    }.each do |setting, reason|
      SiteSetting.public_send("#{setting}=", false)

      get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }

      expect(response).to have_http_status(:service_unavailable)
      expect(response.body).to include(reason)
      SiteSetting.public_send("#{setting}=", true)
    end
  end

  it "rejects false-like or malformed full_app values for a mapped topic" do
    ["false", "0", "TRUE", ["true"]].each do |value|
      get "/embed/comments", params: { topic_id: topic.id, full_app: value }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("exact full_app=true")
    end
  end

  it "leaves an absent full_app request on the ordinary Core embed path" do
    get "/embed/comments", params: { topic_id: topic.id }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("fullInteractive is unavailable")
  end

  it "fails closed when readiness changes after redirect issuance" do
    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
    location = response.location
    SiteSetting.embed_full_app_signin_flow = false

    get location

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include('meta name="discussion-bridge-completed-mapping"')
  end

  it "invalidates an attestation after a same-second microsecond mapping change" do
    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
    location = response.location
    mapping = DiscussionBridgeConnection.find_by!(topic_id: topic.id)
    replacement_usec = mapping.updated_at.usec == 123_456 ? 123_457 : 123_456
    mapping.update_column(:updated_at, mapping.updated_at.change(usec: replacement_usec))

    get location

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include('meta name="discussion-bridge-completed-mapping"')
  end

  it "fails closed after an authentic route attestation expires" do
    issued_at = Time.zone.now
    location = nil
    freeze_time(issued_at) do
      get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
      location = response.location
    end

    freeze_time(issued_at + DiscussionBridge::EmbedRouteAttestation::MAX_AGE + 1.second) do
      get location

      expect(response).to have_http_status(:service_unavailable)
    end
  end

  it "fails closed for an authentic same-topic route whose class or topic usability changes" do
    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
    location = URI.parse(response.location)
    query = Rack::Utils.parse_nested_query(location.query)
    query["class_name"] = "operator-theme"
    location.query = query.to_query

    get location.to_s
    expect(response).to have_http_status(:service_unavailable)

    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
    location = response.location
    topic.update!(closed: true)
    get location

    expect(response).to have_http_status(:service_unavailable)
  end

  it "does not issue an attestation for a policy-drifted completed mapping" do
    topic.update!(visible: true)

    get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include("mapping_topic_visibility_drift")
    expect(response.location).to be_nil
  end

  {
    "listed visibility" => lambda { |example|
      example.__send__(:topic).update!(visible: true)
    },
    "persisted effective visibility" => lambda { |example|
      DiscussionBridgeConnection
        .find_by!(topic_id: example.__send__(:topic).id)
        .update!(effective_visibility: "listed")
    },
    "actor" => lambda { |example|
      example.__send__(:topic).update!(user_id: Fabricate(:user).id)
    },
    "category" => lambda { |example|
      example.__send__(:topic).update!(category: Fabricate(:category))
    },
    "tags" => lambda { |example|
      example.__send__(:topic).tags = [Fabricate(:tag)]
    },
    "lane policy" => lambda { |_example|
      SiteSetting.stubs(:discussion_bridge_lane_policies).returns("{")
    },
    "closed topic" => lambda { |example|
      example.__send__(:topic).update!(closed: true)
    },
    "archived topic" => lambda { |example|
      example.__send__(:topic).update!(archived: true)
    },
    "nonregular archetype" => lambda { |example|
      example.__send__(:topic).update_columns(archetype: Archetype.private_message, category_id: nil)
    },
    "missing first post" => lambda { |example|
      example.__send__(:topic).first_post.update_column(:deleted_at, Time.zone.now)
    },
  }.each do |boundary, mutate|
    it "fails closed when #{boundary} changes after attestation issuance" do
      get "/embed/comments", params: { topic_id: topic.id, full_app: "true" }
      location = response.location
      expect(location).to be_present

      mutate.call(self)
      get location

      expect(response).to have_http_status(:service_unavailable)
      expect(response.body).not_to include('meta name="discussion-bridge-completed-mapping"')
    end
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

  it "accepts absent, blank, and valid bounded mapped class names" do
    reserved = DiscussionBridge::CommentsOnlyPresenter::CSS_CLASS
    maximum_operator = "a" * (
      DiscussionBridge::CommentsOnlyPresenter::MAX_CLASS_NAME_BYTES - reserved.bytesize - 1
    )
    [
      nil,
      "",
      " " * DiscussionBridge::CommentsOnlyPresenter::MAX_CLASS_NAME_BYTES,
      "operator-theme",
      maximum_operator,
      "#{reserved} #{reserved} operator-theme",
    ].each do |class_name|
      params = { topic_id: topic.id, full_app: "true" }
      params[:class_name] = class_name unless class_name.nil?

      get "/embed/comments", params: params

      expect(response).to have_http_status(:redirect)
      query = Rack::Utils.parse_nested_query(URI.parse(response.location).query)
      expect(query.fetch("class_name").split).to include("discussion-bridge-comments-only")
      expect(query.fetch("class_name").split.count(reserved)).to eq(1)
      expect(query.fetch("class_name").bytesize).to be <= DiscussionBridge::CommentsOnlyPresenter::MAX_CLASS_NAME_BYTES
      expect(query["discussion_bridge_embed_token"]).to be_present
    end
  end

  it "rejects invalid mapped class-name shapes without redirect or attestation" do
    reserved = DiscussionBridge::CommentsOnlyPresenter::CSS_CLASS
    one_over_composed = "a" * (
      DiscussionBridge::CommentsOnlyPresenter::MAX_CLASS_NAME_BYTES - reserved.bytesize
    )
    [
      "bad<class",
      one_over_composed,
      "x" * DiscussionBridge::CommentsOnlyPresenter::MAX_CLASS_NAME_BYTES,
      " " * (DiscussionBridge::CommentsOnlyPresenter::MAX_CLASS_NAME_BYTES + 1),
      "\t",
      "\n",
      ["operator-theme"],
      { name: "operator-theme" },
    ].each do |class_name|
      get "/embed/comments",
          params: { topic_id: topic.id, full_app: "true", class_name: class_name }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("valid bounded class_name")
      expect(response.location).to be_nil
      expect(response.body).not_to include("discussion_bridge_embed_token")
      expect(response.body).not_to include('meta name="discussion-bridge-completed-mapping"')
    end
  end

  it "applies the parsed-value contract to repeated mapped query members" do
    get "/embed/comments?topic_id=#{topic.id}&full_app=true&full_app=false"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.location).to be_nil

    get "/embed/comments?topic_id=#{topic.id}&full_app=true&class_name=operator-theme&class_name=bad%3Cclass"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.location).to be_nil
  end

  it "does not impose the mapped class-name contract on an ordinary topic" do
    ordinary_topic = Fabricate(:topic)
    Fabricate(:post, topic: ordinary_topic)

    get "/embed/comments",
        params: { topic_id: ordinary_topic.id, full_app: "true", class_name: "bad<class" }

    expect(response.body).not_to include("valid bounded class_name")
  end

  it "does not add the class for ordinary or incomplete mappings" do
    DiscussionBridgeConnection.update_all(state: "failed")
    get "/embed/comments",
        params: {
          topic_id: topic.id,
          full_app: "true",
          class_name: "discussion-bridge-comments-only",
        }
    expect(response).to redirect_to("#{topic.url}?embed_mode=true")

  end
end
