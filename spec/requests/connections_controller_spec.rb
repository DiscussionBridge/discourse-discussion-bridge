# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::AdapterBridgeRecordsController do
  fab!(:service_actor, :admin)
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = service_actor.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Main WordPress",
      platform: "wordpress",
      allowed_origins: ["https://example.com"],
      allowed_directions: %w[to_discourse from_discourse],
      allowed_lanes: ["articles"],
    )
  end

  def headers(secret: @secret)
    {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => secret,
    }
  end

  def payload(overrides = {})
    {
      bridge_record: {
        direction: "to_discourse",
        external_id: "post-482",
        canonical_url: "https://example.com/articles/community-guide/",
        title: "A controlled companion discussion topic",
        content_html: "<h2>Community guide</h2><p>A complete source article.</p>",
        published: true,
        visibility: "unlisted",
        lane: "articles",
        adapter_id: "wordpress-official",
        adapter_version: "1.0.0",
        correlation_id: "delivery-1",
      }.merge(overrides),
    }
  end

  it "creates one stable Bridge Record and resolves an idempotent retry" do
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    expect(response).to have_http_status(:created), response.body
    created = response.parsed_body

    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "outcome" => "resolved",
      "resource_id" => created.fetch("resource_id"),
      "topic_id" => created.fetch("topic_id"),
      "direction" => "to_discourse",
      "core_fallback" => false,
    )
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
    expect(DiscussionBridgeContentBinding.count).to eq(1)
    expect(DiscussionBridgeBridgeRecord.last.topic).to have_attributes(user_id: service_actor.id, visible: false)
    expect(DiscussionBridgeBridgeRecord.last.topic.first_post.cooked).to include(
      "Community guide",
      "A complete source article.",
      "https://example.com/articles/community-guide/",
    )
    expect(@connection.reload).to have_attributes(adapter_id: "wordpress-official", adapter_version: "1.0.0")
  end

  it "uses a connection-selected visible author and preserves it across later policy changes" do
    selected_author = Fabricate(:user, username: "wordpress_author", trust_level: 1)
    replacement_author = Fabricate(:user, username: "replacement_author", trust_level: 1)
    @connection.update!(author_user: selected_author)

    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    expect(response).to have_http_status(:created), response.body
    record = DiscussionBridgeBridgeRecord.last
    expect(record).to have_attributes(effective_actor_id: selected_author.id)
    expect(record.topic).to have_attributes(user_id: selected_author.id)

    @connection.update!(author_user: replacement_author)
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("outcome")).to eq("resolved")
    expect(record.reload.effective_actor_id).to eq(selected_author.id)
    expect(record.topic.reload.user_id).to eq(selected_author.id)
  end

  it "observes platform authors, holds an unmapped primary, and creates after an operator mapping" do
    mapped_author = Fabricate(:user, username: "mapped_author", trust_level: 1)
    @connection.update!(authorship_mode: "mapped", unmapped_author_policy: "hold")
    authored_payload = payload(
      source_authors: [
        {
          id: "astro:phil",
          name: "Phil",
          profile_url: "https://example.com/authors/phil/",
        },
        { id: "astro:editorial", name: "DiscussionBridge Editorial" },
      ],
      primary_source_author_id: "astro:phil",
    )

    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: authored_payload,
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include("reason" => "source_author_unmapped")
    expect(Topic.count).to eq(0)
    source_author = @connection.source_authors.find_by!(source_author_id: "astro:phil")
    expect(source_author).to have_attributes(
      display_name: "Phil",
      profile_url: "https://example.com/authors/phil/",
      discourse_user_id: nil,
    )

    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}/authors/#{source_author.id}.json",
        params: { source_author: { discourse_username: mapped_author.username } },
        as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("source_author", "discourse_username")).to eq(mapped_author.username)
    sign_out

    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: authored_payload,
         as: :json
    expect(response).to have_http_status(:created), response.body
    record = DiscussionBridgeBridgeRecord.last
    expect(record).to have_attributes(
      effective_actor_id: mapped_author.id,
      primary_source_author_id: "astro:phil",
    )
    expect(record.source_authors.map { |author| author.fetch("id") }).to eq(
      %w[astro:phil astro:editorial],
    )
    expect(record.topic.first_post.cooked).to include(
      "Source authors",
      "Phil",
      "DiscussionBridge Editorial",
      "https://example.com/authors/phil/",
    )
  end

  it "uses the configured fallback for an unmapped author and rejects a profile outside the connection" do
    fallback = Fabricate(:user, username: "fallback_author", trust_level: 1)
    @connection.update!(
      authorship_mode: "mapped",
      unmapped_author_policy: "fallback",
      author_user: fallback,
    )
    authored = {
      source_authors: [{ id: "astro:new", name: "New Astro Author" }],
      primary_source_author_id: "astro:new",
    }
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload(authored),
         as: :json
    expect(response).to have_http_status(:created), response.body
    expect(DiscussionBridgeBridgeRecord.last.topic.user_id).to eq(fallback.id)

    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload(
           external_id: "post-483",
           canonical_url: "https://example.com/articles/second/",
           source_authors: [
             {
               id: "astro:outside",
               name: "Outside",
               profile_url: "https://attacker.invalid/author/",
             },
           ],
           primary_source_author_id: "astro:outside",
         ),
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiscussionBridgeContentBinding.count).to eq(1)
  end

  it "rejects missing, blank, malformed, and oversized source content before mutation" do
    invalid_content = [nil, "", "   ", "<p>bad\u0000content</p>", "x" * (48 * 1024 + 1)]
    invalid_content.each do |content_html|
      body = payload
      if content_html.nil?
        body[:bridge_record].delete(:content_html)
      else
        body[:bridge_record][:content_html] = content_html
      end
      post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: body, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeContentBinding.count).to eq(0)
    expect(Topic.count).to eq(0)
  end

  it "rejects drafts, malformed lifecycle values, bad credentials, and out-of-scope origins before mutation" do
    [
      payload(published: false),
      payload(published: "true"),
      payload(canonical_url: "https://other.example/article"),
      payload(direction: "from_discourse"),
    ].each do |body|
      post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: body, as: :json
      expect(response).not_to have_http_status(:created)
    end

    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers(secret: "wrong-secret-that-is-long-enough-to-test"),
         params: payload,
         as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeContentBinding.count).to eq(0)
  end

  it "fails closed when the same external identity and canonical URL disagree" do
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload(canonical_url: "https://example.com/articles/changed/"),
         as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include(
      "outcome" => "reconciliation_required",
      "reason" => "binding_identity_conflict",
    )
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end

  it "lets an administrator create a From Discourse record and exposes it only to its connection" do
    topic = Fabricate(:topic, user: service_actor, category: category)
    Fabricate(:post, topic: topic, user: service_actor, post_number: 1)
    sign_in(admin)
    post "/discussion-bridge/admin/bridge-records.json",
         params: {
           bridge_record: {
             content_connection_id: @connection.id,
             topic_id: topic.id,
             external_id: "presentation-44",
             canonical_url: "https://example.com/forum-digest/",
           },
         },
         as: :json
    expect(response).to have_http_status(:created)
    resource_id = response.parsed_body.dig("bridge_record", "resource_id")

    sign_out
    expect(@connection.reload.last_seen_at).to be_nil
    get "/discussion-bridge/v1/bridge-records/#{resource_id}.json", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("bridge_record", "direction")).to eq("from_discourse")
    expect(response.parsed_body.dig("bridge_record", "content_html")).to be_present
    expect(@connection.reload.last_seen_at).to be_present
  end

  it "prepares and applies a source migration without changing the resource or topic" do
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    record = DiscussionBridgeBridgeRecord.last
    target, = DiscussionBridgeContentConnection.issue!(
      name: "Documentation Astro",
      platform: "astro",
      allowed_origins: ["https://docs.example.com"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: ["articles"],
    )
    resource_id = record.resource_id
    topic_id = record.topic_id

    sign_in(admin)
    post "/discussion-bridge/admin/bridge-records/#{record.id}/migrations.json",
         params: {
           migration: {
             content_connection_id: target.id,
             external_id: "guide-community",
             canonical_url: "https://docs.example.com/community-guide/",
           },
         },
         as: :json
    expect(response).to have_http_status(:ok)
    prepared_id = response.parsed_body.fetch("prepared_binding_id")

    post "/discussion-bridge/admin/bridge-records/#{record.id}/migrations/#{prepared_id}/apply.json", as: :json
    expect(response).to have_http_status(:ok)
    expect(record.reload).to have_attributes(resource_id: resource_id, topic_id: topic_id, state: "healthy")
    expect(record.content_bindings.pluck(:state)).to contain_exactly("historical", "active")
    expect(record.content_bindings.find_by(state: "active").content_connection).to eq(target)
  end

  it "stops the former connection from reading a record after migration" do
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    record = DiscussionBridgeBridgeRecord.last
    target, target_secret = DiscussionBridgeContentConnection.issue!(
      name: "Replacement Statamic",
      platform: "statamic",
      allowed_origins: ["https://statamic.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: ["articles"],
    )

    sign_in(admin)
    post "/discussion-bridge/admin/bridge-records/#{record.id}/migrations.json",
         params: {
           migration: {
             content_connection_id: target.id,
             external_id: "entry-482",
             canonical_url: "https://statamic.example/community-guide/",
           },
         },
         as: :json
    prepared_id = response.parsed_body.fetch("prepared_binding_id")
    post "/discussion-bridge/admin/bridge-records/#{record.id}/migrations/#{prepared_id}/apply.json", as: :json
    sign_out

    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json",
        headers: {
          "X-DiscussionBridge-Connection" => target.public_id,
          "X-DiscussionBridge-Secret" => target_secret,
        }
    expect(response).to have_http_status(:ok)
  end

  it "paginates a connection's record inventory and rejects invalid pages" do
    get "/discussion-bridge/v1/bridge-records.json", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("pagination")).to include(
      "page" => 1,
      "per_page" => 100,
      "total" => 0,
      "pages" => 1,
    )

    get "/discussion-bridge/v1/bridge-records.json?page=10001", headers: headers
    expect(response).to have_http_status(:bad_request)
  end

  it "creates, updates, and rotates a connection only through native administration" do
    selected_author = Fabricate(:user, username: "publishing_author")
    sign_in(admin)
    post "/discussion-bridge/admin/content-connections.json",
         params: {
           content_connection: {
             name: "Publishing Discourse",
             platform: "discourse",
             author_username: selected_author.username,
             allowed_origins: ["https://publishing.example"],
             allowed_directions: ["from_discourse"],
             allowed_lanes: [],
           },
         },
         as: :json
    expect(response).to have_http_status(:created)
    created = response.parsed_body.fetch("content_connection")
    issued_secret = response.parsed_body.fetch("secret")
    expect(created).to include(
      "platform" => "discourse",
      "author_username" => selected_author.username,
      "author_override" => true,
      "authorship_mode" => "fixed",
      "unmapped_author_policy" => "fallback",
    )

    get "/discussion-bridge/admin/content-connections.json"
    expect(response.parsed_body.to_json).not_to include(issued_secret)
    put "/discussion-bridge/admin/content-connections/#{created.fetch("id")}.json",
        params: { content_connection: { enabled: false, author_username: "" } },
        as: :json
    expect(response.parsed_body.dig("content_connection", "enabled")).to eq(false)
    expect(response.parsed_body.dig("content_connection", "author_override")).to eq(false)
    expect(response.parsed_body.dig("content_connection", "author_username")).to eq(service_actor.username)
    post "/discussion-bridge/admin/content-connections/#{created.fetch("id")}/rotate-secret.json", as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("secret")).not_to eq(issued_secret)
  end
end
