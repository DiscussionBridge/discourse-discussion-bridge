# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::PublisherController do
  fab!(:admin)
  fab!(:moderator)
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

  it "filters retained restricted and private-message publications by current Guardian visibility" do
    restricted_group = Fabricate(:group)
    restricted_category = Fabricate(:private_category, group: restricted_group)
    restricted_topic = topic_with_first_post(category: restricted_category)
    private_topic = Fabricate(:private_message_post, user: admin, recipient: user).topic
    public_a = publish_for_overview!(topic, suffix: "public-a")
    public_b = publish_for_overview!(topic, suffix: "public-b")
    restricted = publish_for_overview!(restricted_topic, suffix: "restricted")
    private_record = publish_for_overview!(private_topic, suffix: "private-message")
    [public_a, public_b].each do |record|
      record.publication_works.update_all(
        state: "available",
        failure_code: nil,
        failure_detail: nil,
        resolution_error: nil,
      )
    end
    mark_attention!(restricted.publication_works.sole, detail: "restricted failure detail")
    mark_attention!(private_record.publication_works.sole, detail: "private failure detail")

    sign_in(moderator)
    get "/discussion-bridge/admin/publishing.json"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("metrics")).to include(
      "published_topics" => 1,
      "presentations" => 2,
    )
    expect(response.parsed_body.dig("metrics", "publication_work", "operator_attention")).to eq(0)
    expect(response.parsed_body.dig("product", "blockers")).not_to include(
      "publication_work_attention",
    )
    expect(response.parsed_body.fetch("recent_records").pluck("resource_id")).to contain_exactly(
      public_a.resource_id,
      public_b.resource_id,
    )
    expect(response.parsed_body.fetch("publication_work").pluck("resource_id")).to contain_exactly(
      public_a.resource_id,
      public_b.resource_id,
    )
    expect(response.parsed_body.fetch("publication_work_pagination")).to include(
      "total" => 2,
      "pages" => 1,
    )
    expect(response.body).not_to include(
      restricted.resource_id,
      restricted.title,
      restricted.active_binding("presentation").canonical_url,
      "restricted failure detail",
      private_record.resource_id,
      private_record.title,
      private_record.active_binding("presentation").canonical_url,
      "private failure detail",
    )

    restricted_group.add(moderator)
    get "/discussion-bridge/admin/publishing.json"
    expect(response.parsed_body.fetch("recent_records").pluck("resource_id")).to include(
      restricted.resource_id,
    )
    expect(response.parsed_body.dig("metrics", "publication_work", "operator_attention")).to eq(1)

    restricted_group.remove(moderator)
    private_topic.allowed_users << moderator
    get "/discussion-bridge/admin/publishing.json"
    expect(response.parsed_body.fetch("recent_records").pluck("resource_id")).to include(
      private_record.resource_id,
    )
    expect(response.parsed_body.fetch("recent_records").pluck("resource_id")).not_to include(
      restricted.resource_id,
    )

    private_topic.topic_allowed_users.find_by!(user_id: moderator.id).destroy!
    get "/discussion-bridge/admin/publishing.json"
    expect(response.body).not_to include(private_record.resource_id, restricted.resource_id)

    sign_in(admin)
    get "/discussion-bridge/admin/publishing.json"
    expect(response.parsed_body.fetch("metrics")).to include(
      "published_topics" => 3,
      "presentations" => 4,
    )
    expect(response.parsed_body.fetch("recent_records").pluck("resource_id")).to contain_exactly(
      public_a.resource_id,
      public_b.resource_id,
      restricted.resource_id,
      private_record.resource_id,
    )

    SiteSetting.suppress_secured_categories_from_admin = true
    get "/discussion-bridge/admin/publishing.json"
    expect(response.parsed_body.fetch("recent_records").pluck("resource_id")).to contain_exactly(
      public_a.resource_id,
      public_b.resource_id,
      private_record.resource_id,
    )
    expect(response.body).not_to include(restricted.resource_id, restricted.title)
  end

  it "keeps unlisted publications visible to staff and omits records whose topic is missing or deleted" do
    unlisted = publish_for_overview!(topic, suffix: "unlisted")
    deleted_topic = topic_with_first_post
    deleted = publish_for_overview!(deleted_topic, suffix: "deleted")
    topic.update!(visible: false)
    deleted_topic.update_column(:deleted_at, Time.zone.now)
    missing = unlisted.dup
    missing.resource_id = SecureRandom.uuid
    missing.topic = nil
    missing.title = "missing topic secret"
    missing.save!

    sign_in(moderator)
    get "/discussion-bridge/admin/publishing.json"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("recent_records").pluck("resource_id")).to eq(
      [unlisted.resource_id],
    )
    expect(response.body).not_to include(
      missing.resource_id,
      missing.title,
      deleted.resource_id,
      deleted.title,
    )

    sign_in(admin)
    get "/discussion-bridge/admin/publishing.json"
    expect(response.parsed_body.fetch("recent_records").pluck("resource_id")).to eq(
      [unlisted.resource_id],
    )
    expect(response.body).not_to include(
      missing.resource_id,
      missing.title,
      deleted.resource_id,
      deleted.title,
    )
  end

  it "denies the publishing overview to ordinary and anonymous users" do
    sign_in(user)
    get "/discussion-bridge/admin/publishing.json"
    expect(response).to have_http_status(:forbidden)

    sign_out
    get "/discussion-bridge/admin/publishing.json"
    expect(response).to have_http_status(:forbidden)
  end

  it "filters hidden work before counts, ordering, pagination, and attention selection" do
    restricted_group = Fabricate(:group)
    restricted_category = Fabricate(:private_category, group: restricted_group)
    restricted_topic = topic_with_first_post(category: restricted_category)
    visible_record = publish_for_overview!(topic, suffix: "page-visible")
    hidden_record = publish_for_overview!(restricted_topic, suffix: "page-hidden")
    visible_source = visible_record.publication_works.sole
    hidden_source = hidden_record.publication_works.sole
    mark_attention!(visible_source, detail: "visible attention 0")
    mark_attention!(hidden_source, detail: "hidden attention 0")
    visible_works = [visible_source]
    hidden_works = [hidden_source]
    50.times do |index|
      visible_works << duplicate_work!(
        visible_source,
        label: "visible-#{index + 1}",
        detail: "visible attention #{index + 1}",
      )
    end
    visible_available = visible_works.last
    visible_available.update!(state: "available", failure_code: nil, failure_detail: nil)
    visible_attention = visible_works.excluding(visible_available)
    49.times do |index|
      hidden_works << duplicate_work!(
        hidden_source,
        label: "hidden-#{index + 1}",
        detail: "hidden attention #{index + 1}",
      )
    end
    visible_works.each_with_index do |work, index|
      work.update_column(:updated_at, 2.hours.ago + index.seconds)
    end
    hidden_works.each_with_index do |work, index|
      work.update_column(:updated_at, 2.hours.from_now + index.seconds)
    end

    sign_in(moderator)
    get "/discussion-bridge/admin/publishing.json", params: { publication_page: 1 }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("publication_work_pagination")).to include(
      "total" => 51,
      "pages" => 2,
      "page" => 1,
      "per_page" => 50,
    )
    expect(response.parsed_body.fetch("publication_work").length).to eq(50)
    expect(response.parsed_body.fetch("publication_work").pluck("work_id")).to eq(
      visible_works.sort_by { |work| [-work.updated_at.to_f, -work.id] }.first(50).map(&:work_id),
    )
    expect(response.parsed_body.dig("metrics", "publication_work", "available")).to eq(1)
    expect(response.parsed_body.dig("metrics", "publication_work", "operator_attention")).to eq(50)
    expect(response.body).not_to include("hidden attention")

    get "/discussion-bridge/admin/publishing.json", params: { publication_page: 2 }
    expect(response.parsed_body.fetch("publication_work").pluck("work_id")).to eq(
      [visible_works.min_by { |work| [work.updated_at, work.id] }.work_id],
    )

    get "/discussion-bridge/admin/publishing.json",
        params: { publication_filter: "attention", publication_page: 1 }
    expect(response.parsed_body.fetch("publication_work_pagination")).to include(
      "total" => 50,
      "pages" => 1,
    )
    expect(response.parsed_body.fetch("publication_work").pluck("work_id")).to eq(
      visible_attention.sort_by { |work| [-work.updated_at.to_f, -work.id] }.map(&:work_id),
    )
    expect(response.parsed_body.fetch("publication_work").pluck("work_id")).not_to include(
      visible_available.work_id,
    )
    expect(response.body).not_to include("hidden attention")
  end

  it "filters hidden records before the recent-record cutoff" do
    restricted_group = Fabricate(:group)
    restricted_category = Fabricate(:private_category, group: restricted_group)
    restricted_topic = topic_with_first_post(category: restricted_category)
    visible = publish_for_overview!(topic, suffix: "recent-visible")
    hidden = publish_for_overview!(restricted_topic, suffix: "recent-hidden")
    visible.update_column(:updated_at, 1.day.ago)
    hidden_records = [hidden]
    19.times do |index|
      hidden_records << hidden.dup.tap do |record|
        record.resource_id = SecureRandom.uuid
        record.title = "hidden recent secret #{index}"
        record.save!
      end
    end
    hidden_records.each_with_index do |record, index|
      record.update_column(:updated_at, 1.hour.from_now + index.seconds)
    end

    sign_in(moderator)
    get "/discussion-bridge/admin/publishing.json"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("recent_records").pluck("resource_id")).to eq(
      [visible.resource_id],
    )
    hidden_records.each do |record|
      expect(response.body).not_to include(record.resource_id, record.title)
    end
  end

  it "applies Guardian visibility in bounded batches for overview metrics and work pages" do
    stub_const(DiscussionBridge::PublisherController, :VISIBILITY_BATCH_SIZE, 2) do
      records = 5.times.map do |index|
        publish_for_overview!(topic_with_first_post, suffix: "bounded-visibility-#{index}")
      end
      visibility_batches = []
      allow_any_instance_of(Guardian).to receive(:can_see_topic_ids).and_wrap_original do |method, topic_ids:|
        visibility_batches << topic_ids
        method.call(topic_ids: topic_ids)
      end

      sign_in(moderator)
      get "/discussion-bridge/admin/publishing.json"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("metrics", "published_topics")).to eq(5)
      expect(response.parsed_body.fetch("publication_work").pluck("resource_id")).to contain_exactly(
        *records.map(&:resource_id),
      )
      expect(visibility_batches).not_to be_empty
      expect(visibility_batches.map(&:length).max).to be <= 2
    end
  end

  it "rejects hidden-topic correction, migration, and retry before side effects" do
    restricted_group = Fabricate(:group)
    restricted_category = Fabricate(:private_category, group: restricted_group)
    restricted_topic = topic_with_first_post(category: restricted_category)
    hidden = publish_for_overview!(restricted_topic, suffix: "hidden-actions")
    hidden_work = hidden.publication_works.sole
    mark_attention!(hidden_work, detail: "hidden actionable detail", code: "internal_error")
    allow(DiscussionBridge::PresentationBindingCorrector).to receive(:call)
    allow(DiscussionBridge::VerifiedUrlMigrator).to receive(:call)

    sign_in(moderator)
    put "/discussion-bridge/v1/publisher/publications/#{hidden.resource_id}/presentation.json",
        params: { publication: { canonical_url: "https://astro.example.com/overview/hidden-corrected/" } },
        as: :json
    expect(response).to have_http_status(:unprocessable_entity)

    put "/discussion-bridge/v1/publisher/publications/#{hidden.resource_id}/migrate-url.json",
        params: {
          migration: {
            old_url: hidden.active_binding("presentation").canonical_url,
            new_url: "https://astro.example.com/overview/hidden-migrated/",
            external_id: hidden.active_binding("presentation").external_id,
            native_identity_confirmed: true,
          },
        },
        as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiscussionBridge::PresentationBindingCorrector).not_to have_received(:call)
    expect(DiscussionBridge::VerifiedUrlMigrator).not_to have_received(:call)

    post "/discussion-bridge/admin/publishing/work/#{hidden_work.id}/retry.json",
         params: { retry: { condition_corrected: true } },
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(hidden_work.reload).to have_attributes(
      state: "operator_attention",
      manual_retry_authorized_at: nil,
      manual_retry_authorized_by_id: nil,
      failure_detail: "hidden actionable detail",
    )

    sign_in(admin)
    post "/discussion-bridge/admin/publishing/work/#{hidden_work.id}/retry.json",
         params: { retry: { condition_corrected: true } },
         as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(hidden_work.reload.state).to eq("available")
  end

  def topic_with_first_post(category: nil)
    Fabricate(:topic, user: admin, category: category).tap do |created_topic|
      Fabricate(:post, topic: created_topic, user: admin, post_number: 1)
    end
  end

  def publish_for_overview!(source_topic, suffix:)
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{source_topic.id}/publish.json",
         params: publication(
           external_id: "overview-#{suffix}",
           canonical_url: "https://astro.example.com/overview/#{suffix}/",
         ),
         as: :json
    expect(response).to have_http_status(:created), response.body
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    DiscussionBridge::SourcePublicationLifecycle.reconcile_topic!(source_topic.id)
    record
  end

  def mark_attention!(work, detail:, code: "operator_action_required")
    work.update!(
      state: "operator_attention",
      failure_code: code,
      failure_detail: detail,
    )
  end

  def duplicate_work!(source, label:, detail:)
    source.dup.tap do |work|
      work.work_id = nil
      work.source_revision = "visibility:#{label}"
      work.source_revision_sequence = source.source_revision_sequence + label.hash.abs + 1
      work.state = "operator_attention"
      work.failure_code = "operator_action_required"
      work.failure_detail = detail
      work.save!
    end
  end
end
