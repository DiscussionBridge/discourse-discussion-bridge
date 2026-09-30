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
    activate_publication!(@connection)
  end

  def activate_publication!(connection)
    profile = connection.platform == "statamic" ? "statamic_db" : connection.platform
    connection.update!(
      destination_policies: [
        {
          "destination_policy_id" => "destination:#{profile}:spec-approved",
          "profile" => profile,
          "presentation_mode" => "interactive",
          "container_mapping" => {
            "source" => "discourse:topics",
            "destination" => "#{profile}:spec-container",
          },
          "taxonomy_mapping" => { "mode" => "source_attribution" },
          "author_mapping" => { "mode" => "source_attribution" },
          "native_limit_policy" => {
            "maximum_bytes" => 49_152,
            "overflow_behavior" => "excerpt_with_read_more",
          },
          "catalog_revision" => "catalog:#{profile}:spec-approved",
        },
      ],
      policy_revision: "policy:#{profile}:spec-approved",
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

  it "changes a presentation URL only after permanent-redirect and native-identity verification" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    created = response.parsed_body
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: created.fetch("resource_id"))
    binding = record.active_binding("presentation")

    allow(DiscussionBridge::PublicationRedirectVerifier).to receive(:call).and_return(301)
    put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/migrate-url.json",
        params: {
          migration: {
            old_url: binding.canonical_url,
            new_url: "https://astro.example.com/discussionbridge/roadmap/",
            external_id: binding.external_id,
            native_identity_confirmed: true,
          },
        },
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "outcome" => "migrated",
      "resource_id" => created.fetch("resource_id"),
      "topic_id" => topic.id,
      "external_id" => "roadmap",
      "canonical_url" => "https://astro.example.com/discussionbridge/roadmap/",
    )
    expect(binding.reload.canonical_url).to eq("https://astro.example.com/discussionbridge/roadmap/")
    expect(record.presentation_url_histories.sole).to have_attributes(
      old_canonical_url: "https://astro.example.com/roadmap/",
      new_canonical_url: "https://astro.example.com/discussionbridge/roadmap/",
      redirect_status: 301,
      verified_by_id: admin.id,
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "from_discourse").count).to eq(1)
  end

  it "refuses the legacy presentation correction route for URL changes" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))

    put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/presentation.json",
        params: { publication: { canonical_url: "https://astro.example.com/discussionbridge/roadmap/" } },
        as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include(
      "presentation URL changes require verified migration and native identity confirmation",
    )
    expect(record.active_binding("presentation").reload.canonical_url).to eq(
      "https://astro.example.com/roadmap/",
    )
  end

  it "rejects a corrected presentation URL outside the connection scope" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    resource_id = response.parsed_body.fetch("resource_id")

    put "/discussion-bridge/v1/publisher/publications/#{resource_id}/presentation.json",
        params: { publication: { canonical_url: "https://wrong.example.com/roadmap/" } },
        as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiscussionBridgeBridgeRecord.find_by!(resource_id: resource_id)
      .active_binding("presentation").canonical_url).to eq("https://astro.example.com/roadmap/")
  end

  it "explicitly authorizes native materialization without adding an undeclared adapter field" do
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
          "X-DiscussionBridge-Contract" => DiscussionBridge::CONTRACT_VERSION,
          "X-DiscussionBridge-Correlation" => "publisher-read-1",
          "HTTPS" => "on",
        }
    expect(response).to have_http_status(:ok)
    binding = response.parsed_body.dig("bridge_record", "bindings").sole
    expect(binding).to include(
      "connection_id" => @connection.public_id,
      "role" => "presentation",
      "state" => "active",
      "external_id" => "roadmap",
      "canonical_url" => "https://astro.example.com/roadmap/",
      "presentation_mode" => "interactive",
    )
    expect(binding.fetch("binding_id")).to match(/\Adbb_[0-9a-f]{32}\z/)
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
    activate_publication!(wordpress)
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
    activate_publication!(scoped)
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
      "X-DiscussionBridge-Contract" => DiscussionBridge::CONTRACT_VERSION,
      "X-DiscussionBridge-Correlation" => "publisher-read-2",
      "HTTPS" => "on",
    }
    get "/discussion-bridge/v1/bridge-records/#{resource_id}.json", headers: headers
    expect(response).to have_http_status(:ok)
    get "/discussion-bridge/v1/bridge-records.json", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("records").map { |record| record.fetch("resource_id") }).to include(resource_id)
  end

  it "requires an explicit allowed lane when a publishing connection permits several" do
    scoped, = DiscussionBridgeContentConnection.issue!(
      name: "Multi-lane Astro",
      platform: "astro",
      allowed_origins: ["https://multi.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: ["news", "guides"],
    )
    activate_publication!(scoped)
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
