# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::AdapterSourceTopicsController do
  fab!(:admin)
  fab!(:category)
  fab!(:tag) { Fabricate(:tag, name: "published") }
  fab!(:second_tag) { Fabricate(:tag, name: "featured") }
  fab!(:topic) { Fabricate(:topic, user: admin, category: category) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "OBBBA WordPress",
      platform: "wordpress",
      allowed_origins: ["https://obbba-wordpress.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
      forum_publication_enabled: true,
      publication_category_mode: "only_selected",
      publication_category_ids: [category.id],
    )
    configure_destination(@connection, "pages")
  end

  def configure_destination(connection, container_id, limits: nil)
    limits ||= { "content_bytes" => 49_152, "title_bytes" => 1_000, "slug_bytes" => 255 }
    catalog_result = DiscussionBridge::PlatformCatalog.call(
      {
        "schema_version" => 1,
        "platform" => connection.platform,
        "containers" => [
          { "id" => container_id, "label" => "Pages", "kind" => "content_type", "taxonomy_ids" => [] },
          { "id" => "archive", "label" => "Archive", "kind" => "collection", "taxonomy_ids" => [] },
        ],
        "taxonomies" => [],
        "authors" => [{ "id" => "user:7", "label" => "Editorial Desk", "kind" => "author" }],
        "service_author_id" => "user:7",
        "presentation_modes" => ["native"],
        "capabilities" => { "updates" => true, "drafts" => true, "unpublish" => true },
        "limits" => limits,
        "inventory" => {
          "authors_complete" => true, "terms_complete" => true,
          "authors_observed" => 1, "terms_observed" => 0,
        },
      },
      platform: connection.platform,
    )
    connection.update!(
      adapter_id: "#{connection.platform}-official",
      adapter_version: "1.0.0",
      platform_catalog: catalog_result.catalog,
      platform_catalog_revision: catalog_result.revision,
      platform_catalog_display_revision: catalog_result.display_revision,
      platform_catalog_adapter_id: "#{connection.platform}-official",
      platform_catalog_adapter_version: "1.0.0",
      platform_catalog_observed_at: Time.zone.now,
    )
    mapping_result = DiscussionBridge::DestinationMapping.call(
      {
        "category_mappings" => [{
          "source_category_id" => category.id,
          "destination_container_id" => container_id,
        }],
        "tag_mappings" => [],
        "unmapped_category_policy" => "hold",
        "unmapped_tag_policy" => "omit",
        "presentation_mode" => "native",
      },
      connection: connection,
    )
    connection.update!(
      destination_mapping: mapping_result.mapping,
      destination_mapping_revision: mapping_result.revision,
      destination_mapping_updated_at: Time.zone.now,
    )
  end

  def publication(revision, origin:, connection: @connection)
    connection.reload
    topic.reload
    topic.association(:tags).reload
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: connection, topic: topic)
    {
      publication: {
        source_revision: revision,
        publication_revision: state.publication_revision,
        mapping_revision: connection.destination_mapping_revision,
        destination: state.destination,
        external_id: "topic-#{topic.id}",
        canonical_url: "#{origin}/topic-#{topic.id}/",
        native_materialization: true,
      },
    }
  end

  def headers(connection: @connection, secret: @secret)
    {
      "X-DiscussionBridge-Connection" => connection.public_id,
      "X-DiscussionBridge-Secret" => secret,
      "X-DiscussionBridge-Adapter" => "#{connection.platform}-official",
      "X-DiscussionBridge-Adapter-Version" => "1.0.0",
    }
  end

  it "previews eligible public topics without creating records" do
    get "/discussion-bridge/v1/source-topics.json", headers: headers

    expect(response).to have_http_status(:ok)
    item = response.parsed_body.fetch("source_topics").find { |row| row.fetch("topic_id") == topic.id }
    expect(item).to include(
      "title" => topic.title,
      "source_revision" => "post:#{first_post.id}:version:#{first_post.version}",
      "source_created_at" => topic.created_at.iso8601(6),
      "publication" => nil,
    )
    expect(DiscussionBridgeBridgeRecord.where(direction: "from_discourse")).to be_empty
  end

  it "excludes a category definition topic from preview and direct source access" do
    category.update_column(:topic_id, topic.id)

    get "/discussion-bridge/v1/source-topics.json", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("source_topics").map { |item| item.fetch("topic_id") })
      .not_to include(topic.id)

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "eligible" => false,
      "reason" => "category_definition_topic",
    )
  end

  it "resolves the same topic independently for two connections" do
    ghost, ghost_secret = DiscussionBridgeContentConnection.issue!(
      name: "OBBBA Ghost",
      platform: "ghost",
      allowed_origins: ["https://obbba-ghost.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
      forum_publication_enabled: true,
      publication_category_mode: "only_selected",
      publication_category_ids: [category.id],
    )
    configure_destination(ghost, "posts")
    revision = "post:#{first_post.id}:version:#{first_post.version}"
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    expect(response).to have_http_status(:created), response.body
    first_resource = response.parsed_body.fetch("resource_id")
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(revision, origin: "https://obbba-ghost.example.com", connection: ghost),
         headers: headers(connection: ghost, secret: ghost_secret), as: :json

    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.fetch("resource_id")).not_to eq(first_resource)
    expect(DiscussionBridgeBridgeRecord.where(topic_id: topic.id, direction: "from_discourse").count).to eq(2)
  end

  it "acknowledges only the authenticated connection and is idempotent" do
    revision = "post:#{first_post.id}:version:#{first_post.version}"
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    expect(response).to have_http_status(:created), response.body
    resource_id = response.parsed_body.fetch("resource_id")
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)
    payload = {
      acknowledgement: {
        source_revision: revision,
        publication_revision: state.publication_revision,
        mapping_revision: @connection.destination_mapping_revision,
        destination: state.destination,
        native_destination: {
          external_id: "topic-#{topic.id}",
          canonical_url: "https://obbba-wordpress.example.com/topic-#{topic.id}/",
        },
        outcome: "created",
      },
    }

    2.times do
      put "/discussion-bridge/v1/bridge-records/#{resource_id}/acknowledgement.json",
          params: payload, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end
    expect(response.parsed_body).to include(
      "outcome" => "resolved",
      "destination_state" => "healthy",
      "delivery_attempt_count" => 1,
    )
    work = DiscussionBridgePublicationWorkItem.find_by!(
      content_connection_id: @connection.id,
      topic_id: topic.id,
    )
    expect(work).to have_attributes(
      action: "publish",
      state: "current",
      bridge_record_id: DiscussionBridgeBridgeRecord.find_by!(resource_id: resource_id).id,
      attempt_count: 1,
    )
  end

  it "queues source changes and priority withdrawals per connection" do
    DiscussionBridge::PublicationWorkQueue.reconcile_topic!(
      topic_id: topic.id,
      connection: @connection,
    )
    work = DiscussionBridgePublicationWorkItem.find_by!(
      content_connection_id: @connection.id,
      topic_id: topic.id,
    )
    expect(work).to have_attributes(
      action: "publish",
      state: "queued",
      reason: "new_publication",
    )

    topic.update!(visible: false)
    DiscussionBridge::PublicationWorkQueue.reconcile_topic!(
      topic_id: topic.id,
      connection: @connection,
    )
    expect(work.reload).to have_attributes(
      action: "publish",
      state: "held",
      reason: "topic_unlisted",
    )

    topic.update!(visible: true)
    revision = DiscussionBridge::PublicationTopicScope.revision(topic)
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    expect(response).to have_http_status(:created), response.body

    topic.update!(visible: false)
    DiscussionBridge::PublicationWorkQueue.reconcile_topic!(
      topic_id: topic.id,
      connection: @connection,
    )
    expect(work.reload).to have_attributes(
      action: "unpublish",
      state: "queued",
      reason: "topic_unlisted",
    )
  end

  it "rejects an acknowledgement computed before the current mapping generation" do
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(state.source_revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    resource_id = response.parsed_body.fetch("resource_id")
    @connection.update_columns(
      destination_mapping: @connection.destination_mapping.merge(
        "category_mappings" => [{
          "source_category_id" => category.id,
          "destination_container_id" => "archive",
        }],
      ),
      destination_mapping_revision: Digest::SHA256.hexdigest("new mapping generation"),
    )
    @connection.mark_from_discourse_publications_pending!

    put "/discussion-bridge/v1/bridge-records/#{resource_id}/acknowledgement.json",
        params: { acknowledgement: {
          source_revision: state.source_revision,
          publication_revision: state.publication_revision,
          mapping_revision: state.destination.fetch("mapping_revision"),
          destination: state.destination,
          native_destination: {
            external_id: "topic-#{topic.id}",
            canonical_url: "https://obbba-wordpress.example.com/topic-#{topic.id}/",
          },
          outcome: "created",
        } }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("reason")).to eq("publication_revision_changed")
    expect(DiscussionBridgeBridgeRecord.find_by!(resource_id: resource_id).destination_state).to eq("pending")
  end

  it "changes the publication revision when visible source content or authorship changes" do
    original = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)

    topic.update!(title: "A changed public title")
    title_revision = DiscussionBridge::TopicPublicationState.for_topic(
      connection: @connection,
      topic: topic.reload,
    ).publication_revision
    expect(title_revision).not_to eq(original.publication_revision)

    first_post.update_columns(cooked: "<p>Changed cooked content</p>")
    content_revision = DiscussionBridge::TopicPublicationState.for_topic(
      connection: @connection,
      topic: topic.reload,
    ).publication_revision
    expect(content_revision).not_to eq(title_revision)

    replacement_author = Fabricate(:user, username: "replacement-author", name: "Replacement Author")
    first_post.update!(user: replacement_author)
    author_state = DiscussionBridge::TopicPublicationState.for_topic(
      connection: @connection,
      topic: topic.reload,
    )
    expect(author_state.publication_revision).not_to eq(content_revision)
    expect(DiscussionBridge::TopicPublicationState.adapter_source(topic).fetch("author")).to include(
      "username" => "replacement-author",
      "name" => "Replacement Author",
      "profile_url" => "#{Discourse.base_url}/u/replacement-author",
    )
  end

  it "adopts an exact legacy publication into forum synchronization without duplicating it" do
    external_id = "topic-#{topic.id}"
    canonical_url = "https://obbba-wordpress.example.com/topic-#{topic.id}/"
    legacy = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: @connection.id,
      topic_id: topic.id,
      external_id: external_id,
      canonical_url: canonical_url,
      native_materialization: true,
    )
    expect(legacy.record.publication_program).to eq("legacy")
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)

    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(state.source_revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      "outcome" => "resolved",
      "resource_id" => legacy.record.resource_id,
      "publication_program" => "forum_sync_pending",
    )
    expect(DiscussionBridgeBridgeRecord.where(topic_id: topic.id, direction: "from_discourse").count).to eq(1)
    put "/discussion-bridge/v1/bridge-records/#{legacy.record.resource_id}/acknowledgement.json",
        params: { acknowledgement: {
          source_revision: state.source_revision,
          publication_revision: state.publication_revision,
          mapping_revision: @connection.destination_mapping_revision,
          destination: state.destination,
          native_destination: {
            external_id: external_id,
            canonical_url: canonical_url,
          },
          outcome: "updated",
        } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(legacy.record.reload.publication_program).to eq("forum_sync")
  end

  it "rejects source revision drift" do
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication("post:#{first_post.id}:version:999", origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiscussionBridgeBridgeRecord.where(topic_id: topic.id)).to be_empty
  end

  it "applies selected tag scope without treating untagged topics as eligible" do
    topic.tags = [tag]
    other_topic = Fabricate(:topic, user: admin, category: category)
    Fabricate(:post, topic: other_topic, user: admin, post_number: 1)
    @connection.update!(publication_tag_mode: "only_selected", publication_tag_ids: [tag.id])

    get "/discussion-bridge/v1/source-topics.json", headers: headers

    ids = response.parsed_body.fetch("source_topics").map { |item| item.fetch("topic_id") }
    expect(ids).to include(topic.id)
    expect(ids).not_to include(other_topic.id)
  end

  it "rejects a claim after the topic category or tags change" do
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)
    payload = publication(state.source_revision, origin: "https://obbba-wordpress.example.com")
    topic.tags = [tag]

    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("publication plan changed")
  end

  it "emits destination taxonomy terms in stable identity order" do
    topic.tags = [second_tag, tag]
    @connection.update_columns(
      destination_mapping: @connection.destination_mapping.merge(
        "tag_mappings" => [
          {
            "source_tag_id" => second_tag.id,
            "destination_taxonomy_id" => "post_tag",
            "destination_term_id" => "post_tag:9",
          },
          {
            "source_tag_id" => tag.id,
            "destination_taxonomy_id" => "post_tag",
            "destination_term_id" => "post_tag:8",
          },
        ],
      ),
    )

    destination = DiscussionBridge::DestinationMapping.resolve(connection: @connection, topic: topic)

    expect(destination.fetch(:destination_terms).map { |item| item.fetch("source_tag_id") }).to eq(
      [tag.id, second_tag.id].sort,
    )
  end

  it "emits a content-free revocation when a published topic becomes ineligible" do
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(state.source_revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    expect(response).to have_http_status(:created), response.body
    resource_id = response.parsed_body.fetch("resource_id")
    topic.update!(visible: false)

    get "/discussion-bridge/v1/source-revocations.json", headers: headers

    item = response.parsed_body.fetch("publication_revocations")
      .find { |row| row.fetch("resource_id") == resource_id }
    expect(item).to include("reason" => "topic_unlisted")
    expect(item).not_to have_key("title")
    expect(item).not_to have_key("content_html")

    put "/discussion-bridge/v1/bridge-records/#{resource_id}/acknowledgement.json",
        params: { acknowledgement: {
          publication_revision: item.fetch("publication_revision"),
          native_destination: {
            external_id: "topic-#{topic.id}",
            canonical_url: "https://obbba-wordpress.example.com/topic-#{topic.id}/",
          },
          outcome: "unpublished",
        } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)

    get "/discussion-bridge/v1/source-revocations.json", headers: headers
    acknowledged = response.parsed_body.fetch("publication_revocations")
      .find { |row| row.fetch("resource_id") == resource_id }
    expect(acknowledged).to include(
      "acknowledged_publication_revision" => item.fetch("publication_revision"),
      "last_delivery_outcome" => "unpublished",
    )
  end

  it "emits a content-free revocation when a published topic becomes the category definition" do
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(state.source_revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    expect(response).to have_http_status(:created), response.body
    resource_id = response.parsed_body.fetch("resource_id")
    category.update_column(:topic_id, topic.id)

    get "/discussion-bridge/v1/source-revocations.json", headers: headers

    item = response.parsed_body.fetch("publication_revocations")
      .find { |row| row.fetch("resource_id") == resource_id }
    expect(item).to include("reason" => "category_definition_topic")
    expect(item).not_to have_key("title")
    expect(item).not_to have_key("content_html")
  end

  it "returns the current revocation state instead of replaying a stale revocation" do
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(state.source_revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    resource_id = response.parsed_body.fetch("resource_id")
    topic.update!(visible: false)

    get "/discussion-bridge/v1/source-revocations/#{resource_id}.json", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("revoked")).to eq(true)

    topic.update!(visible: true)
    get "/discussion-bridge/v1/source-revocations/#{resource_id}.json", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("revoked" => false, "publication_revocation" => nil)
  end

  it "accepts a held acknowledgement when an established publication becomes unmappable" do
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(state.source_revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    resource_id = response.parsed_body.fetch("resource_id")
    @connection.update_columns(
      destination_mapping: @connection.destination_mapping.merge("category_mappings" => []),
      destination_mapping_revision: Digest::SHA256.hexdigest("unmapped"),
    )
    attention = DiscussionBridge::TopicPublicationState.for_topic(
      connection: @connection.reload,
      topic: topic.reload,
    )

    put "/discussion-bridge/v1/bridge-records/#{resource_id}/acknowledgement.json",
        params: { acknowledgement: {
          source_revision: attention.source_revision,
          publication_revision: attention.publication_revision,
          mapping_revision: attention.destination.fetch("mapping_revision"),
          destination: attention.destination,
          native_destination: {
            external_id: "topic-#{topic.id}",
            canonical_url: "https://obbba-wordpress.example.com/topic-#{topic.id}/",
          },
          outcome: "held",
        } }, headers: headers, as: :json

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("destination_state" => "held")
    expect(DiscussionBridgeBridgeRecord.find_by!(resource_id: resource_id).last_delivery_outcome).to eq("held")
  end

  it "uses a terminating keyset run while ordinary topic edits continue" do
    20.times do
      candidate = Fabricate(:topic, user: admin, category: category)
      Fabricate(:post, topic: candidate, user: admin, post_number: 1)
    end
    get "/discussion-bridge/v1/source-topics.json", headers: headers
    first_ids = response.parsed_body.fetch("source_topics").map { |item| item.fetch("topic_id") }
    cursor = response.parsed_body.dig("pagination", "next_cursor")
    expect(cursor).to be_present
    topic.update!(title: "Edited while the run is active")

    get "/discussion-bridge/v1/source-topics.json", params: { cursor: cursor }, headers: headers

    expect(response).to have_http_status(:ok)
    second_ids = response.parsed_body.fetch("source_topics").map { |item| item.fetch("topic_id") }
    expect((first_ids + second_ids).uniq.length).to eq(21)
    expect(response.parsed_body.dig("pagination", "complete")).to eq(true)
  end

  it "rejects a keyset cursor after the connection publication policy changes" do
    20.times do
      candidate = Fabricate(:topic, user: admin, category: category)
      Fabricate(:post, topic: candidate, user: admin, post_number: 1)
    end
    get "/discussion-bridge/v1/source-topics.json", headers: headers
    cursor = response.parsed_body.dig("pagination", "next_cursor")
    @connection.update!(publication_include_unlisted: true)

    get "/discussion-bridge/v1/source-topics.json", params: { cursor: cursor }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("source feed cursor is stale")
    expect(response.parsed_body).to include(
      "outcome" => "rejected",
      "reason" => "source_feed_cursor_stale",
    )

    get "/discussion-bridge/v1/source-topics.json", params: { cursor: "not-a-cursor" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include(
      "outcome" => "rejected",
      "reason" => "invalid_source_feed_cursor",
    )
  end

  it "uses the bounded forum-publication content boundary without widening inbound creation" do
    maximum = DiscussionBridge::BridgeRecordRequest::MAX_PUBLICATION_CONTENT_HTML_BYTES
    expect(maximum).to be > DiscussionBridge::BridgeRecordRequest::MAX_CONTENT_HTML_BYTES
    configure_destination(
      @connection,
      "pages",
      limits: { "content_bytes" => 10 * 1024 * 1024, "title_bytes" => 1_000, "slug_bytes" => 255 },
    )
    first_post.update_columns(cooked: "x" * (maximum + 1))

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json", headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include(
      "reason" => "source_content_too_large",
      "maximum_bytes" => maximum,
    )
  end

  it "keeps a worst-case escaped source detail inside the adapter response budget" do
    configure_destination(
      @connection,
      "pages",
      limits: {
        "content_bytes" => DiscussionBridge::BridgeRecordRequest::MAX_PUBLICATION_CONTENT_HTML_BYTES,
        "title_bytes" => 1_000,
        "slug_bytes" => 255,
      },
    )
    first_post.update_columns(
      cooked: "\u0001" * DiscussionBridge::BridgeRecordRequest::MAX_PUBLICATION_CONTENT_HTML_BYTES,
    )

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to be <= 2 * 1024 * 1024
    expect(response.parsed_body.dig("source_topic", "content_html").bytesize).to eq(
      DiscussionBridge::BridgeRecordRequest::MAX_PUBLICATION_CONTENT_HTML_BYTES,
    )
  end

  it "holds content outside the adapter limits in both preview and source planning" do
    first_post.update_columns(cooked: "<p>#{'x' * 20}</p>")
    configure_destination(
      @connection,
      "pages",
      limits: { "content_bytes" => 10, "title_bytes" => 1_000, "slug_bytes" => 255 },
    )
    sign_in(admin)

    get "/discussion-bridge/admin/content-connections/#{@connection.id}/publication-preview.json"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("ready" => 0, "held" => 1)
    expect(response.parsed_body.fetch("held_reasons")).to include("source_content_too_large" => 1)

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include(
      "reason" => "source_content_too_large",
      "maximum_bytes" => 10,
    )
  end

  it "plans against the receiver limit when the adapter advertises a larger content limit" do
    maximum = DiscussionBridge::BridgeRecordRequest::MAX_PUBLICATION_CONTENT_HTML_BYTES
    first_post.update_columns(cooked: "<p>#{'x' * maximum}</p>")
    configure_destination(
      @connection,
      "pages",
      limits: { "content_bytes" => 10 * 1024 * 1024, "title_bytes" => 1_000, "slug_bytes" => 255 },
    )
    sign_in(admin)

    get "/discussion-bridge/admin/content-connections/#{@connection.id}/publication-preview.json"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("ready" => 0, "held" => 1)
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection.reload, topic: topic.reload)
    expect(state.destination).to include(
      "state" => "attention",
      "limits" => include("content_bytes" => maximum),
      "reasons" => include("source_content_too_large"),
    )
  end

  it "changes the generic feed snapshot when publication ownership transfers" do
    legacy = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: @connection.id,
      topic_id: topic.id,
      external_id: "topic-#{topic.id}",
      canonical_url: "https://obbba-wordpress.example.com/topic-#{topic.id}/",
      native_materialization: true,
    ).record
    relation = DiscussionBridgeBridgeRecord.joins(:content_bindings)
      .where(discussion_bridge_content_bindings: { content_connection_id: @connection.id })
    before = DiscussionBridge::AdapterFeedSnapshot.capture(relation)

    legacy.update!(publication_program: "forum_sync_pending")
    after = DiscussionBridge::AdapterFeedSnapshot.capture(relation)

    expect(after.digest).not_to eq(before.digest)
  end

  it "keeps legacy materializer records outside forum-sync pending and revocation ownership" do
    legacy = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: @connection.id,
      topic_id: topic.id,
      external_id: "topic-#{topic.id}",
      canonical_url: "https://obbba-wordpress.example.com/topic-#{topic.id}/",
      native_materialization: true,
    ).record
    @connection.mark_from_discourse_publications_pending!
    expect(legacy.reload.destination_state).to be_nil
    topic.update!(visible: false)

    get "/discussion-bridge/v1/source-revocations.json", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("publication_revocations")).to be_empty
  end

  it "marks an existing publication pending when its destination mapping changes" do
    revision = DiscussionBridge::PublicationTopicScope.revision(topic)
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    expect(response).to have_http_status(:created), response.body
    resource_id = response.parsed_body.fetch("resource_id")
    state = DiscussionBridge::TopicPublicationState.for_topic(connection: @connection, topic: topic)
    put "/discussion-bridge/v1/bridge-records/#{resource_id}/acknowledgement.json",
        params: { acknowledgement: {
          source_revision: state.source_revision,
          publication_revision: state.publication_revision,
          mapping_revision: @connection.destination_mapping_revision,
          destination: state.destination,
          native_destination: {
            external_id: "topic-#{topic.id}",
            canonical_url: "https://obbba-wordpress.example.com/topic-#{topic.id}/",
          },
          outcome: "created",
        } }, headers: headers, as: :json
    sign_in(admin)

    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: { content_connection: { destination_mapping: {
          category_mappings: [{
            source_category_id: category.id,
            destination_container_id: "archive",
          }],
          tag_mappings: [],
          unmapped_category_policy: "hold",
          unmapped_tag_policy: "omit",
          presentation_mode: "native",
        } } }, as: :json

    expect(response).to have_http_status(:ok)
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: resource_id)
    expect(record.destination_state).to eq("pending")
    expect(record.acknowledged_mapping_revision).not_to eq(@connection.reload.destination_mapping_revision)
  end

  it "atomically leases queued publication work and requires the lease for acknowledgement" do
    DiscussionBridge::PublicationWorkQueue.reconcile_topic!(
      topic_id: topic.id,
      connection: @connection,
    )

    post "/discussion-bridge/v1/publication-work/claim.json",
         params: { lease_seconds: 3600 }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    work = response.parsed_body.fetch("publication_work")
    expect(work).to include(
      "topic_id" => topic.id,
      "action" => "publish",
      "reason" => "new_publication",
      "source_revision" => DiscussionBridge::PublicationTopicScope.revision(topic),
    )
    expect(work.fetch("lease_token")).to match(/\A[0-9a-f]{64}\z/)
    expect(Time.zone.parse(work.fetch("lease_expires_at"))).to be > 50.minutes.from_now

    post "/discussion-bridge/v1/publication-work/claim.json", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("publication_work")).to be_nil

    revision = DiscussionBridge::PublicationTopicScope.revision(topic)
    post "/discussion-bridge/v1/source-topics/#{topic.id}/resolve.json",
         params: publication(revision, origin: "https://obbba-wordpress.example.com"),
         headers: headers, as: :json
    expect(response).to have_http_status(:created), response.body
    resource_id = response.parsed_body.fetch("resource_id")
    state = DiscussionBridge::TopicPublicationState.for_topic(
      connection: @connection.reload,
      topic: topic.reload,
    )

    put "/discussion-bridge/v1/bridge-records/#{resource_id}/acknowledgement.json",
        params: { acknowledgement: {
          source_revision: state.source_revision,
          publication_revision: state.publication_revision,
          mapping_revision: @connection.destination_mapping_revision,
          destination: state.destination,
          native_destination: {
            external_id: "topic-#{topic.id}",
            canonical_url: "https://obbba-wordpress.example.com/topic-#{topic.id}/",
          },
          outcome: "created",
        } }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include("reason" => "invalid_publication_lease")

    put "/discussion-bridge/v1/bridge-records/#{resource_id}/acknowledgement.json",
        params: { acknowledgement: {
          lease_token: work.fetch("lease_token"),
          source_revision: state.source_revision,
          publication_revision: state.publication_revision,
          mapping_revision: @connection.destination_mapping_revision,
          destination: state.destination,
          native_destination: {
            external_id: "topic-#{topic.id}",
            canonical_url: "https://obbba-wordpress.example.com/topic-#{topic.id}/",
          },
          outcome: "created",
        } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(DiscussionBridgePublicationWorkItem.find_by!(topic_id: topic.id).state).to eq("current")
  end

  it "reclaims expired publication work before leasing new queued work" do
    queued_topic = Fabricate(:topic, user: admin, category: category)
    Fabricate(:post, topic: queued_topic, user: admin, post_number: 1)
    retry_topic = Fabricate(:topic, user: admin, category: category)
    Fabricate(:post, topic: retry_topic, user: admin, post_number: 1)

    [queued_topic, retry_topic].each do |candidate|
      DiscussionBridge::PublicationWorkQueue.reconcile_topic!(
        topic_id: candidate.id,
        connection: @connection,
      )
    end

    queued_item = DiscussionBridgePublicationWorkItem.find_by!(topic_id: queued_topic.id)
    queued_item.update!(available_at: 1.hour.ago)
    retry_item = DiscussionBridgePublicationWorkItem.find_by!(topic_id: retry_topic.id)
    retry_item.update!(
      state: "claimed",
      lease_token: SecureRandom.hex(32),
      claimed_at: 2.hours.ago,
      lease_expires_at: 1.minute.ago,
      available_at: nil,
      attempt_count: 1,
    )

    post "/discussion-bridge/v1/publication-work/claim.json", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("publication_work")).to include(
      "topic_id" => retry_topic.id,
      "attempt_count" => 2,
    )
    expect(queued_item.reload).to have_attributes(state: "queued", attempt_count: 0)
  end

  it "records bounded adapter failures against the exact publication lease" do
    DiscussionBridge::PublicationWorkQueue.reconcile_topic!(
      topic_id: topic.id,
      connection: @connection,
    )

    3.times do |index|
      post "/discussion-bridge/v1/publication-work/claim.json", headers: headers, as: :json
      work = response.parsed_body.fetch("publication_work")
      expect(work.fetch("attempt_count")).to eq(index + 1)

      put "/discussion-bridge/v1/publication-work/failure.json",
          params: { publication_work_failure: {
            lease_token: work.fetch("lease_token"),
            error_code: "wordpress_delivery_failed",
            error_detail: "Native publication did not complete.",
          } }, headers: headers, as: :json
      expect(response).to have_http_status(:ok), response.body
      item = DiscussionBridgePublicationWorkItem.find_by!(topic_id: topic.id)
      expect(item.state).to eq(index == 2 ? "failed" : "retrying")
      expect(item.last_error_code).to eq("wordpress_delivery_failed")
      item.update!(available_at: 1.minute.ago) unless index == 2
    end

    post "/discussion-bridge/v1/publication-work/claim.json", headers: headers, as: :json
    expect(response.parsed_body.fetch("publication_work")).to be_nil
  end

  it "notifies configured operator groups once when publication needs attention" do
    SiteSetting.discussion_bridge_attention_groups = Group::AUTO_GROUPS[:admins].to_s
    first_post.update_columns(cooked: "<p>content exceeds the platform limit</p>")
    configure_destination(
      @connection,
      "pages",
      limits: { "content_bytes" => 10, "title_bytes" => 1_000, "slug_bytes" => 255 },
    )

    2.times do
      DiscussionBridge::PublicationWorkQueue.reconcile_topic!(
        topic_id: topic.id,
        connection: @connection.reload,
      )
    end

    item = DiscussionBridgePublicationWorkItem.find_by!(topic_id: topic.id)
    expect(item).to have_attributes(state: "attention", reason: "source_content_too_large")
    notifications = Notification.where(
      user: admin,
      notification_type: Notification.types[:custom],
    )
    expect(notifications.count).to eq(1)
    expect(JSON.parse(notifications.first.data)).to include(
      "title" => "discussion_bridge.notification.attention_title",
      "discussion_bridge_connection_id" => @connection.public_id,
    )
  end
end
