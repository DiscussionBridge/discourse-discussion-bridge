# frozen_string_literal: true

require "base64"
require "rails_helper"

describe "DiscussionBridge Adapter Protocol Alpha.21 source publication" do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Alpha.21 source WordPress",
      platform: "wordpress",
      allowed_origins: ["https://publisher.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: ["articles"],
      destination_policies: [destination_policy],
      catalog_required: false,
      policy_revision: "policy:2026-09-27:3",
    )
  end

  def destination_policy
    {
      "destination_policy_id" => "destination:wordpress:articles:1",
      "profile" => "wordpress",
      "presentation_mode" => "interactive",
      "container_mapping" => {
        "source" => "discourse:category:articles",
        "destination" => "site:articles",
      },
      "taxonomy_mapping" => { "mode" => "mapped_only" },
      "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => {
        "maximum_bytes" => 49_152,
        "overflow_behavior" => "excerpt_with_read_more",
      },
      "catalog_revision" => "catalog:wordpress:2026-09-27:1",
    }
  end

  def headers(correlation: "source-publication-1")
    {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => DiscussionBridge::CONTRACT_VERSION,
      "X-DiscussionBridge-Correlation" => correlation,
      "HTTPS" => "on",
    }
  end

  def create_source(title: "Source topic", content: "<p>Source body</p>", suffix: SecureRandom.hex(4))
    topic = Fabricate(:topic, user: admin, category: category, title: title, visible: true)
    raw = content.bytesize > 32_000 ? "Large source body" : content
    post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: raw)
    post.update_columns(cooked: content)
    result = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: @connection.id,
      topic_id: topic.id,
      external_id: "page-#{suffix}",
      canonical_url: "https://publisher.example/articles/#{suffix}/",
      lane: "articles",
      native_materialization: true,
    )
    [topic, post, result.record]
  end

  def inventory(params: {}, correlation: "source-inventory-1")
    get "/discussion-bridge/v1/source-topics.json",
        headers: headers(correlation: correlation),
        params: params
  end

  it "creates an exact immutable snapshot and paginates it with a bound opaque cursor" do
    first_topic, = create_source(title: "First source")
    create_source(title: "Second source")

    inventory(params: { limit: 1 })
    expect(response).to have_http_status(:ok), response.body
    first_page = response.parsed_body
    expect(first_page.keys).to contain_exactly(*DiscussionBridge::SourcePublicationProtocol::INVENTORY_RESPONSE_FIELDS)
    expect(first_page.fetch("snapshot")).to match(DiscussionBridge::SourcePublicationProtocol::SNAPSHOT_ID_PATTERN)
    expect(first_page.fetch("items").sole.keys).to contain_exactly(
      *DiscussionBridge::SourcePublicationProtocol::INVENTORY_ITEM_FIELDS,
    )
    expect(first_page.fetch("items").sole.fetch("topic_id")).to eq(first_topic.id)
    expect(first_page.fetch("complete")).to eq(false)

    create_source(title: "Created after snapshot")
    inventory(
      params: {
        limit: 1,
        snapshot: first_page.fetch("snapshot"),
        cursor: first_page.fetch("next_cursor"),
      },
      correlation: "source-inventory-2",
    )
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("items").length).to eq(1)
    expect(response.parsed_body.fetch("complete")).to eq(true)

    inventory(correlation: "source-inventory-3")
    expect(response.parsed_body.fetch("items").length).to eq(3)

    inventory(
      params: {
        snapshot: "dbs_#{"0" * 32}",
        cursor: first_page.fetch("next_cursor"),
      },
      correlation: "source-inventory-4",
    )
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("cursor_snapshot_mismatch")
  end

  it "retains and returns exact revision-pinned first-post detail after a later source edit" do
    topic, post, record = create_source(content: "<p>Original first post</p>")
    Fabricate(:post, topic: topic, user: admin, raw: "reply must never be transported")
    inventory
    initial = response.parsed_body.fetch("items").sole

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json",
        headers: headers(correlation: "source-detail-1"),
        params: { source_revision: initial.fetch("source_revision") }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.keys).to contain_exactly(
      *DiscussionBridge::SourcePublicationProtocol::DETAIL_FIELDS,
    )
    expect(response.parsed_body.dig("content_transport", "content_html")).to eq("<p>Original first post</p>")
    expect(response.body).not_to include("reply must never be transported")

    post.update_columns(cooked: "<p>Updated first post</p>", updated_at: 1.minute.from_now)
    topic.update_columns(updated_at: 1.minute.from_now)
    inventory(correlation: "source-inventory-edited")
    latest = response.parsed_body.fetch("items").sole
    expect(latest.fetch("source_revision_sequence")).to be > initial.fetch("source_revision_sequence")

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json",
        headers: headers(correlation: "source-detail-old"),
        params: { source_revision: initial.fetch("source_revision") }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("content_transport", "content_html")).to eq("<p>Original first post</p>")
    expect(record.reload.source_revision).to eq(latest.fetch("source_revision"))
  end

  it "serializes one retained revision instead of mixing later live topic content" do
    topic, post, record = create_source(
      title: "Retained publication title",
      content: "<p>Retained body</p>",
    )
    inventory
    retained = record.source_revisions.order(:source_revision_sequence).last
    topic.update_columns(title: "Unmaterialized live title")
    post.update_columns(cooked: "<p>Unmaterialized live body</p>", updated_at: 1.minute.from_now)

    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json",
        headers: headers(correlation: "retained-record-detail")
    expect(response).to have_http_status(:ok), response.body
    payload = response.parsed_body.fetch("bridge_record")
    expect(payload).to include(
      "title" => retained.title,
      "source_revision" => retained.source_revision,
      "source_revision_sequence" => retained.source_revision_sequence,
    )
    expect(payload.dig("content_transport", "content_html")).to eq("<p>Retained body</p>")
    expect(payload.dig("content_transport", "sha256")).to eq(retained.content_sha256)
    binding = record.active_binding("presentation")
    expect(payload.fetch("bindings").sole).to include(
      "binding_id" => binding.binding_id,
      "connection_id" => @connection.public_id,
      "role" => "presentation",
      "state" => "active",
      "external_id" => binding.external_id,
      "canonical_url" => binding.canonical_url,
    )
  end

  it "uses exact bounded chunks for source content larger than the inline ceiling" do
    content = "<p>#{"x" * 70_000}</p>"
    topic, = create_source(content: content)
    inventory
    revision = response.parsed_body.dig("items", 0, "source_revision")

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json",
        headers: headers(correlation: "source-chunk-detail"),
        params: { source_revision: revision }
    descriptor = response.parsed_body.fetch("content_transport")
    expect(descriptor.keys).to contain_exactly(
      *DiscussionBridge::SourcePublicationProtocol::CHUNK_DESCRIPTOR_FIELDS,
    )
    expect(descriptor).to include(
      "mode" => "chunked",
      "decoded_chunk_maximum_bytes" => 32_768,
      "byte_length" => content.bytesize,
    )

    decoded = +""
    1.upto(descriptor.fetch("chunk_count")) do |chunk|
      get "/discussion-bridge/v1/source-topics/#{topic.id}/content.json",
          headers: headers(correlation: "source-chunk-#{chunk}"),
          params: { source_revision: revision, chunk: chunk }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.keys).to contain_exactly(
        *DiscussionBridge::SourcePublicationProtocol::CONTENT_FIELDS,
      )
      bytes = Base64.strict_decode64(response.parsed_body.fetch("content_base64"))
      expect(bytes.bytesize).to be <= 32_768
      expect(Digest::SHA256.hexdigest(bytes)).to eq(response.parsed_body.fetch("chunk_sha256"))
      decoded << bytes
    end
    expect(decoded).to eq(content)
    expect(Digest::SHA256.hexdigest(decoded)).to eq(descriptor.fetch("sha256"))
  end

  it "fails closed before persisting source content beyond the contract maximum" do
    _, post, record = create_source
    post.update_columns(
      cooked: "x" * (DiscussionBridge::SourcePublicationProtocol::MAXIMUM_SOURCE_CONTENT_BYTES + 1),
    )

    expect do
      DiscussionBridge::SourceRevisionMaterializer.call(record: record, connection: @connection)
    end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) do |error|
      expect(error.error_code).to eq("content_unsupported")
    end
    expect(record.source_revisions).to be_empty
  end

  it "denies retained revision and chunk reads after current scope narrows" do
    content = "<p>#{"x" * 70_000}</p>"
    topic, = create_source(content: content)
    inventory
    revision = response.parsed_body.dig("items", 0, "source_revision")
    @connection.update!(allowed_lanes: ["news"])

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json",
        headers: headers(correlation: "source-narrowed-detail"),
        params: { source_revision: revision }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error_code")).to eq("scope_denied")

    get "/discussion-bridge/v1/source-topics/#{topic.id}/content.json",
        headers: headers(correlation: "source-narrowed-chunk"),
        params: { source_revision: revision, chunk: 1 }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error_code")).to eq("scope_denied")
  end

  it "expires inactive snapshots without mutating source publication state" do
    create_source
    inventory
    snapshot_id = response.parsed_body.fetch("snapshot")
    DiscussionBridgeSourceSnapshot.find_by!(snapshot_id: snapshot_id).update_columns(
      expires_at: 1.second.ago,
    )

    inventory(params: { snapshot: snapshot_id }, correlation: "source-expired")
    expect(response).to have_http_status(:gone)
    expect(response.parsed_body.fetch("error_code")).to eq("snapshot_expired")
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end

  it "records bounded revocations and restores through a new higher source revision" do
    topic, = create_source
    second_topic, = create_source(title: "Second revoked source")
    inventory
    initial_sequence = response.parsed_body.fetch("items").find do |item|
      item.fetch("topic_id") == topic.id
    end.fetch("source_revision_sequence")
    topic.update_columns(visible: false)
    second_topic.update_columns(visible: false)

    get "/discussion-bridge/v1/source-revocations.json",
        headers: headers(correlation: "revocations-1"),
        params: { limit: 1 }
    expect(response).to have_http_status(:ok), response.body
    index = response.parsed_body
    expect(index.keys).to contain_exactly(*DiscussionBridge::SourcePublicationProtocol::REVOCATION_INDEX_FIELDS)
    item = index.fetch("items").sole
    expect(item.keys).to contain_exactly(*DiscussionBridge::SourcePublicationProtocol::REVOCATION_ITEM_FIELDS)
    expect(item).to include("reason" => "source_unpublished", "restorable" => true)
    expect(item.fetch("source_revision_sequence")).to be > initial_sequence

    get "/discussion-bridge/v1/source-revocations.json",
        headers: headers(correlation: "revocations-mismatch"),
        params: {
          limit: 1,
          high_water: "#{index.fetch("high_water")}x",
          cursor: index.fetch("next_cursor"),
        }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("cursor_snapshot_mismatch")

    resource_id = item.fetch("resource_id")
    get "/discussion-bridge/v1/source-revocations/#{resource_id}.json",
        headers: headers(correlation: "revocation-detail-1")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.keys).to contain_exactly(
      *DiscussionBridge::SourcePublicationProtocol::REVOCATION_DETAIL_FIELDS,
    )

    topic.update_columns(visible: true, updated_at: 1.minute.from_now)
    inventory(correlation: "source-restored")
    restored_sequence = response.parsed_body.fetch("items").sole.fetch("source_revision_sequence")
    expect(restored_sequence).to be > item.fetch("source_revision_sequence")
    expect(DiscussionBridgeSourceRevocation.find_by!(revocation_id: item.fetch("revocation_id")).restored_at).to be_present
  end

  it "fails closed for unknown fields, malformed bounds, unknown revisions, and denied direction" do
    topic, = create_source
    inventory(params: { limit: 101 }, correlation: "source-invalid-limit")
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error_code")).to eq("malformed_value")

    inventory(params: { unexpected: true }, correlation: "source-unknown-field")
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error_code")).to eq("unknown_field")

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json",
        headers: headers(correlation: "source-unknown-revision"),
        params: { source_revision: "missing-revision" }
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.fetch("error_code")).to eq("revision_not_found")

    @connection.update!(allowed_directions: ["to_discourse"], destination_policies: [
      destination_policy.merge("profile" => "discourse_as_publisher"),
    ])
    inventory(correlation: "source-direction-denied")
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error_code")).to eq("direction_denied")
  end

  it "does not return retained snapshot metadata after scope narrows" do
    create_source(title: "Allowed first topic")
    create_source(title: "Removed-scope title")
    inventory(params: { limit: 1 }, correlation: "snapshot-first")
    first = response.parsed_body
    @connection.update!(allowed_lanes: ["news"])
    inventory(
      params: { limit: 1, snapshot: first.fetch("snapshot"), cursor: first.fetch("next_cursor") },
      correlation: "snapshot-resume-denied",
    )
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error_code")).to eq("scope_denied")
    expect(response.body).not_to include("Removed-scope title")
  end
end
