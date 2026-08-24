# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::ConnectionsController do
  it "does not expose creation while the plugin is disabled" do
    SiteSetting.discussion_bridge_enabled = false
    post "/discussion-bridge/connections/resolve.json", params: {}
    expect(response.status).to eq(404)
    expect(response.parsed_body).to include("error_type" => "not_found")
  end

  fab!(:service_actor, :admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_connection_id = "astro"
    SiteSetting.discussion_bridge_connection_secret = "test-secret"
    SiteSetting.discussion_bridge_trusted_origins = "https://example.com"
    SiteSetting.discussion_bridge_service_username = service_actor.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
  end

  def request_headers(secret: "test-secret")
    {
      "X-DiscussionBridge-Connection" => "astro",
      "X-DiscussionBridge-Secret" => secret,
    }
  end

  def connection_payload(overrides = {})
    {
      connection: {
        connection_id: "astro",
        adapter_id: "astro",
        source_url: "https://example.com/articles/controlled",
        title: "A controlled companion discussion topic",
        visibility: "listed",
        lane: "articles",
        correlation_id: "request-1",
      }.merge(overrides),
    }
  end

  it "rejects malformed connection containers without persistence or exception leakage" do
    [nil, false, true, "connection", 1, [], ["nested"]].each do |container|
      post "/discussion-bridge/connections/resolve.json",
           headers: request_headers,
           params: { connection: container },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("reason" => "invalid_request")
      expect(DiscussionBridgeConnection.count).to eq(0)
      expect(DiscussionBridgeAuditEvent.count).to eq(0)
    end

    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers,
         params: {},
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include("reason" => "invalid_request")
  end

  it "rejects a bad connection credential before creating or auditing anything" do
    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers(secret: "wrong"),
         params: connection_payload

    expect(response.status).to eq(401)
    expect(response.parsed_body).to include("reason" => "unauthorized", "core_fallback" => false)
    expect(DiscussionBridgeConnection.count).to eq(0)
    expect(DiscussionBridgeAuditEvent.count).to eq(0)
  end

  it "creates once as the service actor, forces unlisted, audits, and resolves an idempotent retry" do
    2.times do
      post "/discussion-bridge/connections/resolve.json",
           headers: request_headers,
           params: connection_payload
    end

    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "outcome" => "resolved",
      "reason" => "existing_mapping",
      "core_fallback" => false,
    )
    expect(response.parsed_body.dig("requested", "visibility")).to eq("listed")
    expect(response.parsed_body.dig("effective", "visibility")).to eq("unlisted")

    mapping = DiscussionBridgeConnection.find_by!(connection_id: "astro")
    expect(mapping).to have_attributes(state: "complete", effective_actor_id: service_actor.id)
    expect(mapping.topic).to have_attributes(user_id: service_actor.id, visible: false)
    expect(mapping.topic.first_post.raw).to include("https://example.com/articles/controlled")
    expect(DiscussionBridgeConnection.count).to eq(1)
    expect(DiscussionBridgeAuditEvent.pluck(:outcome)).to eq(%w[created resolved])
  end

  it "accepts the authenticated server request with production forgery protection enabled" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers,
         params: connection_payload

    expect(response.status).to eq(201)
    expect(response.parsed_body).to include("outcome" => "created", "core_fallback" => false)
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  it "uses the forum-owned category and tags for an explicitly configured lane" do
    lane_category = Fabricate(:category)
    lane_tag = Fabricate(:tag, name: "bridge-docs")
    SiteSetting.discussion_bridge_lane_policies = [
      {
        lane: "articles",
        category_id: lane_category.id,
        tags: [lane_tag.name],
        visibility: "unlisted",
      },
    ].to_json

    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers,
         params: connection_payload(category_id: category.id, tags: ["adapter-request"])

    expect(response.status).to eq(201)
    expect(response.parsed_body.dig("effective", "category_id")).to eq(lane_category.id)
    expect(response.parsed_body.dig("effective", "tags")).to eq([lane_tag.name])
    expect(DiscussionBridgeConnection.last.topic).to have_attributes(category_id: lane_category.id)
    expect(DiscussionBridgeConnection.last.topic.tags.pluck(:name)).to eq([lane_tag.name])
  end

  it "rejects and audits an unknown lane when forum lane policies are configured" do
    SiteSetting.discussion_bridge_lane_policies = [
      { lane: "docs", category_id: category.id, tags: [], visibility: "unlisted" },
    ].to_json

    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers,
         params: connection_payload(lane: "unknown")

    expect(response.status).to eq(422)
    expect(response.parsed_body).to include("outcome" => "rejected", "reason" => "lane_denied")
    expect(DiscussionBridgeConnection.count).to eq(0)
    expect(DiscussionBridgeAuditEvent.last).to have_attributes(outcome: "rejected", reason: "lane_denied")
  end

  it "fails closed when forum authority rejects the effective category" do
    category.destroy!
    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers,
         params: connection_payload

    expect(response.status).to eq(422)
    expect(response.parsed_body).to include("outcome" => "rejected", "reason" => "category_unavailable")
    expect(DiscussionBridgeConnection.count).to eq(0)
    expect(DiscussionBridgeAuditEvent.last).to have_attributes(outcome: "rejected", reason: "category_unavailable")
  end

  it "rejects an operating identity that cannot create the enforced unlisted topic" do
    ordinary_actor = Fabricate(:user, trust_level: TrustLevel[1])
    SiteSetting.discussion_bridge_service_username = ordinary_actor.username

    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers,
         params: connection_payload

    expect(response.status).to eq(422)
    expect(response.parsed_body).to include("outcome" => "rejected", "reason" => "unlisted_denied")
    expect(DiscussionBridgeConnection.count).to eq(0)
    expect(DiscussionBridgeAuditEvent.last).to have_attributes(outcome: "rejected", reason: "unlisted_denied")
  end

  it "rejects an incomplete nested request without persistence" do
    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers,
         params: { connection: { connection_id: "astro", source_url: "https://example.com/articles/incomplete" } }

    expect(response.status).to eq(422)
    expect(response.parsed_body).to include("outcome" => "rejected", "reason" => "invalid_request")
    expect(DiscussionBridgeConnection.count).to eq(0)
    expect(DiscussionBridgeAuditEvent.count).to eq(0)
  end

  it "rejects unknown, wrongly typed, and oversized request fields before persistence" do
    invalid_payloads = [
      connection_payload(unknown: "field"),
      connection_payload(adapter_id: { nested: true }),
      connection_payload(correlation_id: "x" * 201),
      connection_payload(tags: Array.new(21, "tag")),
    ]

    invalid_payloads.each do |payload|
      post "/discussion-bridge/connections/resolve.json",
           headers: request_headers,
           params: payload
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("reason" => "invalid_request")
    end
    expect(DiscussionBridgeConnection.count).to eq(0)
    expect(DiscussionBridgeAuditEvent.count).to eq(0)
  end

  it "returns reconciliation_required instead of a successful binding for a deleted mapped topic" do
    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers,
         params: connection_payload
    mapping = DiscussionBridgeConnection.last
    mapping.topic.update!(deleted_at: Time.zone.now)

    post "/discussion-bridge/connections/resolve.json",
         headers: request_headers,
         params: connection_payload

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include(
      "outcome" => "reconciliation_required",
      "reason" => "mapping_topic_deleted",
      "topic_id" => nil,
    )
    expect(mapping.reload).to have_attributes(state: "complete")
  end
end
