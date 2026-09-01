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

  def publication(connection: @connection, external_id: "roadmap", canonical_url: "https://astro.example.com/roadmap/", native_materialization: false)
    {
      publication: {
        content_connection_id: connection.id,
        external_id: external_id,
        canonical_url: canonical_url,
        native_materialization: native_materialization,
      },
    }
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
    expect(response.body).not_to include("X-DiscussionBridge-Secret")
  end
end
