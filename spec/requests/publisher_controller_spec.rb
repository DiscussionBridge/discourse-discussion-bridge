# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::PublisherController do
  fab!(:admin)
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Astro Demo",
      platform: "astro",
      allowed_origins: ["https://astro.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    )
  end

  def publication(connection: @connection, external_id: "roadmap", canonical_url: "https://astro.example.com/roadmap/", lane: :omitted, native_materialization: false)
    payload = {
      publication: {
        content_connection_id: connection.id,
        external_id: external_id,
        canonical_url: canonical_url,
        native_materialization: native_materialization,
      },
    }
    payload[:publication][:lane] = lane unless lane == :omitted
    payload
  end

  it "requires a staff session" do
    sign_in(user)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "creates and exactly resolves a local From Discourse publication" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    expect(response).to have_http_status(:created)
    created = response.parsed_body
    expect(created).to include(
      "outcome" => "created",
      "topic_id" => topic.id,
      "platform" => "astro",
      "canonical_url" => "https://astro.example.com/roadmap/",
    )

    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "outcome" => "resolved",
      "resource_id" => created.fetch("resource_id"),
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "from_discourse").count).to eq(1)
    expect(DiscussionBridgeContentBinding.last.native_materialization).to eq(false)
  end

  it "explicitly authorizes native materialization and exposes it to the adapter" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(native_materialization: true),
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("native_materialization")).to eq(true)
    record = DiscussionBridgeBridgeRecord.last
    expect(record.active_binding("presentation").native_materialization).to eq(true)

    sign_out
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json",
        headers: {
          "X-DiscussionBridge-Connection" => @connection.public_id,
          "X-DiscussionBridge-Secret" => @secret,
        }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("bridge_record", "bindings", 0, "native_materialization")).to eq(true)
  end

  it "rejects malformed native materialization authority" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(native_materialization: "yes"),
         as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiscussionBridgeBridgeRecord.where(direction: "from_discourse")).to be_empty
  end

  it "publishes one local topic independently to more than one platform" do
    wordpress, = DiscussionBridgeContentConnection.issue!(
      name: "WordPress Demo",
      platform: "wordpress",
      allowed_origins: ["https://wordpress.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    )
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(
           connection: wordpress,
           external_id: "roadmap-wp",
           canonical_url: "https://wordpress.example.com/roadmap/",
         ),
         as: :json

    expect(response).to have_http_status(:created)
    records = DiscussionBridgeBridgeRecord.where(direction: "from_discourse", topic_id: topic.id)
    expect(records.count).to eq(2)
    expect(records.pluck(:resource_id).uniq.count).to eq(2)
  end

  it "assigns a single allowed lane and exposes the publication to that connection" do
    scoped, secret = DiscussionBridgeContentConnection.issue!(
      name: "Lane-scoped Statamic",
      platform: "statamic",
      allowed_origins: ["https://statamic.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: ["statamic-demo"],
    )
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(
           connection: scoped,
           canonical_url: "https://statamic.example.com/roadmap/",
         ),
         as: :json

    expect(response).to have_http_status(:created)
    resource_id = response.parsed_body.fetch("resource_id")
    expect(response.parsed_body.fetch("lane")).to eq("statamic-demo")
    expect(DiscussionBridgeBridgeRecord.last.lane).to eq("statamic-demo")

    sign_out
    headers = {
      "X-DiscussionBridge-Connection" => scoped.public_id,
      "X-DiscussionBridge-Secret" => secret,
    }
    get "/discussion-bridge/v1/bridge-records/#{resource_id}.json", headers: headers
    expect(response).to have_http_status(:ok)
    get "/discussion-bridge/v1/bridge-records.json", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("bridge_records").map { |record| record.fetch("resource_id") }).to include(resource_id)
  end

  it "requires an explicit allowed lane when a publishing connection permits several" do
    scoped, = DiscussionBridgeContentConnection.issue!(
      name: "Multi-lane Astro",
      platform: "astro",
      allowed_origins: ["https://multi.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: ["news", "guides"],
    )
    sign_in(admin)
    attributes = {
      connection: scoped,
      canonical_url: "https://multi.example.com/roadmap/",
    }

    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(**attributes),
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("lane is required for this connection")

    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(**attributes, lane: "other"),
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("lane is outside connection scope")

    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(**attributes, lane: "guides"),
         as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("lane")).to eq("guides")
  end

  it "rejects a destination outside the selected connection" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(canonical_url: "https://wrong.example.com/roadmap/"),
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiscussionBridgeBridgeRecord.where(direction: "from_discourse")).to be_empty
  end

  it "exposes no publishing route while publishing is disabled" do
    SiteSetting.discussion_bridge_publisher_enabled = false
    sign_in(admin)
    get "/discussion-bridge/v1/publisher/topics/#{topic.id}/status.json"
    expect(response).to have_http_status(:not_found)
  end

  it "returns a secret-free native publishing overview" do
    sign_in(admin)
    get "/discussion-bridge/admin/publishing.json"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("product", "blockers")).to eq([])
    expect(response.parsed_body.dig("connections", 0, "public_id")).to eq(@connection.public_id)
    expect(response.parsed_body.dig("connections", 0, "allowed_lanes")).to eq([])
    expect(response.body).not_to include("X-DiscussionBridge-Secret")
  end
end
