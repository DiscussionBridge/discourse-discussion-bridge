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
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Astro Demo",
        platform: "astro",
        allowed_origins: ["https://astro.example.com"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: [],
      )
  end

  def publication(
    connection: @connection,
    external_id: "roadmap",
    canonical_url: "https://astro.example.com/roadmap/",
    lane: :omitted,
    native_materialization: false
  )
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

  it "does not authorize republishing a native Core imported article as forum-owned content" do
    TopicEmbed.create!(topic: topic, post: first_post, embed_url: "https://source.example/article/")
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    expect(response).to have_http_status(:forbidden)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "denies initial publication of a first post hidden by native moderation" do
    SiteSetting.hidden_post_visible_groups = Group::AUTO_GROUPS[:staff].to_s
    first_post.hide!(PostActionType.types[:spam])
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    expect(response).to have_http_status(:forbidden)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
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
    expect(DiscussionBridgeContentBinding.last.presentation_mode).to be_nil
  end

  it "stores an actual selected presentation without changing the binding on repeat publication" do
    sign_in(admin)
    input = publication
    input[:publication][:presentation_mode] = "simple"
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: input, as: :json
    expect(response).to have_http_status(:created)
    record = DiscussionBridgeBridgeRecord.last
    binding = record.active_binding("presentation")
    expect(binding.presentation_mode).to eq("simple")
    expect(response.parsed_body.fetch("presentation_mode")).to eq("simple")
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    expect(response).to have_http_status(:ok)
    expect(binding.reload.presentation_mode).to eq("simple")
    input[:publication][:presentation_mode] = "full"
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: input, as: :json
    expect(response).to have_http_status(:ok)
    expect(record.reload.active_binding("presentation")).to have_attributes(
      id: binding.id,
      presentation_mode: "full",
    )
    input[:publication][:presentation_mode] = nil
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: input, as: :json
    expect(response).to have_http_status(:ok)
    expect(binding.reload.presentation_mode).to be_nil
  end

  it "rejects noncanonical presentation choices without creating a publication" do
    sign_in(admin)
    %w[fullInteractive from_discourse INVALID].each do |mode|
      input = publication
      input[:publication][:presentation_mode] = mode
      post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
           params: input,
           as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "does not authorize public publication of private or known external-source first posts" do
    sign_in(admin)
    private_category = Fabricate(:category, read_restricted: true)
    topic.update!(category_id: private_category.id)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    expect(response).to have_http_status(:forbidden)
    topic.update!(category_id: SiteSetting.uncategorized_category_id)
    DiscussionBridgeBridgeRecord.create!(
      resource_id: SecureRandom.uuid,
      direction: "to_discourse",
      state: "healthy",
      topic_id: topic.id,
      title: "Known external source",
      effective_actor_id: admin.id,
    )
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    expect(response).to have_http_status(:forbidden)
    expect(DiscussionBridgeBridgeRecord.where(direction: "from_discourse").count).to eq(0)
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
        params: {
          publication: {
            canonical_url: "https://astro.example.com/discussionbridge/roadmap/",
          },
        },
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "outcome" => "presentation_corrected",
      "resource_id" => created.fetch("resource_id"),
      "topic_id" => topic.id,
      "external_id" => "roadmap",
      "canonical_url" => "https://astro.example.com/discussionbridge/roadmap/",
    )
    expect(binding.reload.canonical_url).to eq(
      "https://astro.example.com/discussionbridge/roadmap/",
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "from_discourse").count).to eq(1)
  end

  it "rejects a corrected presentation URL outside the connection scope" do
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params: publication,
         as: :json
    resource_id = response.parsed_body.fetch("resource_id")

    put "/discussion-bridge/v1/publisher/publications/#{resource_id}/presentation.json",
        params: {
          publication: {
            canonical_url: "https://wrong.example.com/roadmap/",
          },
        },
        as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(
      DiscussionBridgeBridgeRecord
        .find_by!(resource_id: resource_id)
        .active_binding("presentation")
        .canonical_url,
    ).to eq("https://astro.example.com/roadmap/")
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
    expect(
      response.parsed_body.dig("bridge_record", "bindings", 0, "native_materialization"),
    ).to eq(true)
  end

  %w[ordinary wiki].each do |source_kind|
    it "returns current #{source_kind} source edits without replacing the publication binding" do
      first_post.update!(wiki: source_kind == "wiki")
      sign_in(admin)
      post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
           params: publication,
           as: :json
      expect(response).to have_http_status(:created)
      resource_id = response.parsed_body.fetch("resource_id")
      record = DiscussionBridgeBridgeRecord.find_by!(resource_id: resource_id)
      binding = record.active_binding("presentation")
      original_version = first_post.reload.version
      updated_title = "Updated #{source_kind} source title"
      updated_body = "This #{source_kind} source body changed after publication."

      expect(
        first_post.revise(
          admin,
          { title: updated_title, raw: updated_body },
          force_new_version: true,
        ),
      ).to eq(true)
      first_post.reload
      expect(first_post.version).to eq(original_version + 1)
      sign_out

      get "/discussion-bridge/v1/bridge-records/#{resource_id}.json",
          headers: {
            "X-DiscussionBridge-Connection" => @connection.public_id,
            "X-DiscussionBridge-Secret" => @secret,
          }
      expect(response).to have_http_status(:ok)
      payload = response.parsed_body.fetch("bridge_record")
      expect(payload).to include(
        "resource_id" => resource_id,
        "topic_id" => topic.id,
        "title" => updated_title,
      )
      expect(payload.fetch("content_html")).to include(updated_body)
      expect(payload.fetch("source")).to include(
        "revision" => "post:#{first_post.id}:version:#{first_post.version}",
        "post_version" => first_post.version,
        "updated_at" => first_post.updated_at.iso8601(6),
      )
      expect(payload.fetch("bindings")).to contain_exactly(
        include(
          "role" => "presentation",
          "state" => "active",
          "external_id" => binding.external_id,
          "canonical_url" => binding.canonical_url,
        ),
      )
      expect(record.reload.active_binding("presentation").id).to eq(binding.id)
    end

    it "returns a new edition for a #{source_kind} title-only edit with the same source body and identity" do
      first_post.update!(wiki: source_kind == "wiki")
      sign_in(admin)
      post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
           params: publication,
           as: :json
      expect(response).to have_http_status(:created)
      resource_id = response.parsed_body.fetch("resource_id")
      binding =
        DiscussionBridgeBridgeRecord.find_by!(resource_id: resource_id).active_binding(
          "presentation",
        )
      original_body = first_post.reload.cooked
      original_version = first_post.version
      updated_title = "Updated #{source_kind} title without a source body edit"

      expect(first_post.revise(admin, { title: updated_title })).to eq(true)
      expect(first_post.reload.version).to eq(original_version + 1)
      get "/discussion-bridge/v1/publisher/topics/#{topic.id}/status.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("publications")).to contain_exactly(
        include("resource_id" => resource_id, "topic_id" => topic.id, "title" => updated_title),
      )
      sign_out

      get "/discussion-bridge/v1/bridge-records/#{resource_id}.json",
          headers: {
            "X-DiscussionBridge-Connection" => @connection.public_id,
            "X-DiscussionBridge-Secret" => @secret,
          }
      expect(response).to have_http_status(:ok)
      payload = response.parsed_body.fetch("bridge_record")
      expect(payload).to include(
        "resource_id" => resource_id,
        "topic_id" => topic.id,
        "title" => updated_title,
      )
      expect(payload.fetch("content_html")).to eq(original_body)
      expect(payload.fetch("source").fetch("post_version")).to eq(first_post.version)
      expect(
        DiscussionBridgeBridgeRecord
          .find_by!(resource_id: resource_id)
          .active_binding("presentation")
          .id,
      ).to eq(binding.id)
    end

    it "distinguishes a #{source_kind} grace-period source edit from an exact edition retry" do
      first_post.update!(
        wiki: source_kind == "wiki",
        last_editor_id: admin.id,
        last_version_at: Time.zone.now,
      )
      sign_in(admin)
      post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
           params: publication,
           as: :json
      expect(response).to have_http_status(:created)
      resource_id = response.parsed_body.fetch("resource_id")
      record = DiscussionBridgeBridgeRecord.find_by!(resource_id: resource_id)
      binding = record.active_binding("presentation")
      sign_out
      adapter_headers = {
        "X-DiscussionBridge-Connection" => @connection.public_id,
        "X-DiscussionBridge-Secret" => @secret,
      }
      get "/discussion-bridge/v1/bridge-records/#{resource_id}.json", headers: adapter_headers
      original = response.parsed_body.fetch("bridge_record")
      original_version = first_post.reload.version
      updated_body =
        "This #{source_kind} source edit occurred inside the native revision grace period."

      expect(first_post.revise(admin, { raw: updated_body })).to eq(true)
      expect(first_post.reload.version).to eq(original_version)
      get "/discussion-bridge/v1/bridge-records/#{resource_id}.json", headers: adapter_headers
      expect(response).to have_http_status(:ok)
      updated = response.parsed_body.fetch("bridge_record")
      expect(updated).to include("resource_id" => resource_id, "topic_id" => topic.id)
      expect(updated.fetch("content_html")).to include(updated_body)
      expect(updated.fetch("source").fetch("revision")).to eq(
        original.fetch("source").fetch("revision"),
      )
      expect(updated.fetch("source").fetch("edition")).not_to eq(
        original.fetch("source").fetch("edition"),
      )
      get "/discussion-bridge/v1/bridge-records/#{resource_id}.json", headers: adapter_headers
      expect(response.parsed_body.fetch("bridge_record").fetch("source").fetch("edition")).to eq(
        updated.fetch("source").fetch("edition"),
      )
      expect(record.reload.active_binding("presentation").id).to eq(binding.id)
    end
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
    wordpress, =
      DiscussionBridgeContentConnection.issue!(
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
         params:
           publication(
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
    scoped, secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Lane-scoped Statamic",
        platform: "statamic",
        allowed_origins: ["https://statamic.example.com"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["statamic-demo"],
      )
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json",
         params:
           publication(connection: scoped, canonical_url: "https://statamic.example.com/roadmap/"),
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
    expect(
      response.parsed_body.fetch("bridge_records").map { |record| record.fetch("resource_id") },
    ).to include(resource_id)
  end

  it "requires an explicit allowed lane when a publishing connection permits several" do
    scoped, =
      DiscussionBridgeContentConnection.issue!(
        name: "Multi-lane Astro",
        platform: "astro",
        allowed_origins: ["https://multi.example.com"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: %w[news guides],
      )
    sign_in(admin)
    attributes = { connection: scoped, canonical_url: "https://multi.example.com/roadmap/" }

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
