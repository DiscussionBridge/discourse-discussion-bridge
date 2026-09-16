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

  it "lets staff correct only the presentation URL without replacing its identity" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    created = response.parsed_body
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: created.fetch("resource_id"))
    binding = record.active_binding("presentation")

    put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/presentation.json",
        params: { publication: { canonical_url: "https://astro.example.com/discussionbridge/roadmap/" } },
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "outcome" => "presentation_corrected",
      "resource_id" => created.fetch("resource_id"),
      "topic_id" => topic.id,
      "external_id" => "roadmap",
      "canonical_url" => "https://astro.example.com/discussionbridge/roadmap/",
    )
    expect(binding.reload.canonical_url).to eq("https://astro.example.com/discussionbridge/roadmap/")
    expect(DiscussionBridgeBridgeRecord.where(direction: "from_discourse").count).to eq(1)
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

  it "does not silently correct the URL of a native publication without migration" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(native_materialization: true),
         as: :json
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    binding = record.active_binding("presentation")

    put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/presentation.json",
        params: { publication: { canonical_url: "https://astro.example.com/moved-roadmap/" } },
        as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(binding.reload.canonical_url).to eq("https://astro.example.com/roadmap/")
    expect(record.reload.state).to eq("healthy")
  end

  it "rejects the generic migration for native presentations, preserving their identity" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(native_materialization: true),
         as: :json
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    target, = DiscussionBridgeContentConnection.issue!(
      name: "Second Astro destination",
      platform: "astro",
      allowed_origins: ["https://docs.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    )

    post "/discussion-bridge/admin/bridge-records/#{record.id}/migrations.json",
         params: {
           migration: {
             content_connection_id: target.id,
             external_id: "second-roadmap",
             canonical_url: "https://docs.example.com/moved-roadmap/",
           },
         },
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("presentation migration requires a verified URL cutover")
    expect(record.reload.active_binding("presentation").native_materialization).to eq(true)
    expect(record.state).to eq("healthy")
    expect(record.topic_id).to eq(topic.id)
  end

  it "moves a native publication URL in place after redirect verification and reserves the old URL" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(native_materialization: true),
         as: :json
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    binding = record.active_binding("presentation")
    original_id = binding.id
    old_url = binding.canonical_url
    new_url = "https://astro.example.com/new-roadmap/"
    allow(DiscussionBridge::PublicationRedirectVerifier).to receive(:call)
      .with(old_url: old_url, new_url: new_url).and_return(301)

    2.times do |attempt|
      put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/migrate-url.json",
          params: { migration: { old_url: old_url, new_url: new_url } },
          as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "outcome" => attempt.zero? ? "migrated" : "already_current",
        "resource_id" => record.resource_id,
        "topic_id" => topic.id,
        "canonical_url" => new_url,
        "redirect_status" => 301,
      )
    end

    expect(record.reload).to have_attributes(state: "healthy", topic_id: topic.id)
    expect(record.active_binding("presentation")).to have_attributes(
      id: original_id,
      external_id: "roadmap",
      canonical_url: new_url,
      native_materialization: true,
    )
    expect(DiscussionBridgePresentationUrlHistory.count).to eq(1)
    expect(DiscussionBridgePresentationUrlHistory.last).to have_attributes(
      content_binding_id: original_id,
      old_canonical_url: old_url,
      new_canonical_url: new_url,
      redirect_status: 301,
    )

    sign_out
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json",
        headers: {
          "X-DiscussionBridge-Connection" => @connection.public_id,
          "X-DiscussionBridge-Secret" => @secret,
        }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("bridge_record", "bindings", 0, "url_migration")).to include(
      "old_url" => old_url,
      "new_url" => new_url,
      "redirect_status" => 301,
    )
    sign_in(admin)

    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(external_id: "different", canonical_url: old_url, native_materialization: true),
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("publication URL is reserved by migration history")
    expect(DiscussionBridgeBridgeRecord.where(direction: "from_discourse").count).to eq(1)

    second_topic = Fabricate(:topic, user: admin)
    Fabricate(:post, topic: second_topic, user: admin, post_number: 1)
    post "/discussion-bridge/v1/publisher/topics/#{second_topic.id}/publish.json",
         params: publication(external_id: "second", canonical_url: "https://astro.example.com/second/"),
         as: :json
    second_resource_id = response.parsed_body.fetch("resource_id")
    put "/discussion-bridge/v1/publisher/publications/#{second_resource_id}/presentation.json",
        params: { publication: { canonical_url: old_url } },
        as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("presentation URL is reserved by migration history")
    expect(DiscussionBridgeBridgeRecord.find_by!(resource_id: second_resource_id)
      .active_binding("presentation").canonical_url).to eq("https://astro.example.com/second/")

    allow(DiscussionBridge::PublicationRedirectVerifier).to receive(:call)
      .with(old_url: new_url, new_url: old_url).and_return(308)
    2.times do |attempt|
      put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/migrate-url.json",
          params: { migration: { old_url: new_url, new_url: old_url } },
          as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "outcome" => attempt.zero? ? "migrated" : "already_current",
        "resource_id" => record.resource_id,
        "topic_id" => topic.id,
        "canonical_url" => old_url,
        "redirect_status" => 308,
      )
    end
    expect(record.reload.active_binding("presentation")).to have_attributes(
      id: original_id,
      canonical_url: old_url,
      external_id: "roadmap",
    )
    expect(DiscussionBridgePresentationUrlHistory.where(content_binding_id: original_id).count).to eq(2)

    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(native_materialization: true),
         as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("outcome" => "resolved", "resource_id" => record.resource_id)
  end

  it "requires exact staff confirmation before migrating an older native publication" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    binding = record.active_binding("presentation")
    old_url = binding.canonical_url
    new_url = "https://astro.example.com/new-roadmap/"
    allow(DiscussionBridge::PublicationRedirectVerifier).to receive(:call)
      .with(old_url: old_url, new_url: new_url).and_return(301)

    [{}, { legacy_native_confirmation: true, platform_content_id: "wrong" }].each do |extra|
      put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/migrate-url.json",
          params: { migration: { old_url: old_url, new_url: new_url }.merge(extra) },
          as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors")).to include("legacy native publication confirmation is required")
      expect(binding.reload).to have_attributes(canonical_url: old_url, native_materialization: false)
      expect(DiscussionBridgePresentationUrlHistory.count).to eq(0)
    end

    2.times do |attempt|
      put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/migrate-url.json",
          params: {
            migration: {
              old_url: old_url,
              new_url: new_url,
              legacy_native_confirmation: true,
              platform_content_id: binding.external_id,
            },
          },
          as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "outcome" => attempt.zero? ? "migrated" : "already_current",
        "resource_id" => record.resource_id,
        "topic_id" => topic.id,
        "canonical_url" => new_url,
        "native_materialization" => true,
      )
    end
    expect(binding.reload).to have_attributes(
      canonical_url: new_url,
      native_materialization: true,
      external_id: "roadmap",
    )
    expect(record.reload.topic_id).to eq(topic.id)
    expect(DiscussionBridgePresentationUrlHistory.count).to eq(1)
  end

  it "does not promote an older publication when redirect verification fails" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    binding = record.active_binding("presentation")
    old_url = binding.canonical_url
    allow(DiscussionBridge::PublicationRedirectVerifier).to receive(:call)
      .and_raise(ArgumentError, "old publication URL does not return a permanent redirect")

    put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/migrate-url.json",
        params: {
          migration: {
            old_url: old_url,
            new_url: "https://astro.example.com/new-roadmap/",
            legacy_native_confirmation: true,
            platform_content_id: binding.external_id,
          },
        },
        as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(binding.reload).to have_attributes(canonical_url: old_url, native_materialization: false)
    expect(DiscussionBridgePresentationUrlHistory.count).to eq(0)
  end

  it "keeps the native publication unchanged when redirect verification fails" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication(native_materialization: true),
         as: :json
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    old_url = record.active_binding("presentation").canonical_url
    allow(DiscussionBridge::PublicationRedirectVerifier).to receive(:call)
      .and_raise(ArgumentError, "old publication URL does not return a permanent redirect")

    put "/discussion-bridge/v1/publisher/publications/#{record.resource_id}/migrate-url.json",
        params: { migration: { old_url: old_url, new_url: "https://astro.example.com/new-roadmap/" } },
        as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(record.reload.active_binding("presentation").canonical_url).to eq(old_url)
    expect(DiscussionBridgePresentationUrlHistory.count).to eq(0)
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
