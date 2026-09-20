# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::AdapterPlatformCatalogController do
  fab!(:admin)
  fab!(:category)
  fab!(:tag) { Fabricate(:tag, name: "policy") }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "OBBBA WordPress",
      platform: "wordpress",
      allowed_origins: ["https://obbba-wordpress.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    )
  end

  def headers(version: "1.0.0")
    {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Adapter" => "wordpress-official",
      "X-DiscussionBridge-Adapter-Version" => version,
    }
  end

  def catalog(platform: "wordpress")
    payload = {
      catalog: {
        schema_version: 1,
        platform: platform,
        containers: [{ id: "post", label: "Posts", kind: "post_type", taxonomy_ids: ["post_tag"] }],
        taxonomies: [{
          id: "post_tag", label: "Tags", kind: "taxonomy",
          terms: [{ id: "policy", label: "Policy", kind: "term" }],
        }],
        authors: [{ id: "user:7", label: "Editorial Desk", kind: "author" }],
        service_author_id: "user:7",
        presentation_modes: ["native"],
        capabilities: { updates: true, drafts: true, unpublish: true },
        inventory: {
          authors_complete: true, terms_complete: true, authors_observed: 1, terms_observed: 1,
        },
      },
    }
    revision = @connection.reload.platform_catalog_revision
    payload[:expected_catalog_revision] = revision if revision.present?
    payload
  end

  it "accepts a bounded native platform catalog and records its identity" do
    put "/discussion-bridge/v1/platform-catalog.json", params: catalog, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("catalog_revision")).to match(/\A[0-9a-f]{64}\z/)
    expect(@connection.reload.platform_catalog.dig("containers", 0, "id")).to eq("post")
    expect(@connection.platform_catalog_observed_at).to be_present
  end

  it "rejects a catalog for a different platform" do
    put "/discussion-bridge/v1/platform-catalog.json",
        params: catalog(platform: "ghost"), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(@connection.reload.platform_catalog).to eq({})
  end

  it "rejects incomplete adapter inventory before it can become a mapping basis" do
    incomplete = catalog
    incomplete[:catalog][:inventory][:terms_complete] = false

    put "/discussion-bridge/v1/platform-catalog.json",
        params: incomplete, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("platform inventory is incomplete")
    expect(@connection.reload.platform_catalog).to eq({})
    expect(@connection.destination_mapping_revision).to be_nil
  end

  it "requires an exact adapter identity before binding a catalog" do
    incomplete = headers.except("X-DiscussionBridge-Adapter-Version")

    put "/discussion-bridge/v1/platform-catalog.json", params: catalog,
        headers: incomplete, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(@connection.reload.adapter_id).to be_nil
    expect(@connection.platform_catalog).to eq({})
  end

  it "stores receiver-owned mappings against stable catalog ids" do
    put "/discussion-bridge/v1/platform-catalog.json", params: catalog, headers: headers, as: :json
    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: { content_connection: { destination_mapping: {
          category_mappings: [{
            source_category_id: category.id,
            destination_container_id: "post",
          }],
          tag_mappings: [],
          unmapped_category_policy: "hold",
          unmapped_tag_policy: "omit",
          presentation_mode: "native",
          authorship_policy: "fixed",
          destination_author_id: "user:7",
          slug_policy: "topic_id",
        } } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(@connection.reload.destination_mapping_revision).to match(/\A[0-9a-f]{64}\z/)
    expect(@connection.destination_mapping.dig("category_mappings", 0)).to include(
      "source_category_id" => category.id,
      "destination_container_id" => "post",
    )
    expect(@connection.destination_mapping).to include(
      "authorship_policy" => "fixed",
      "destination_author_id" => "user:7",
      "slug_policy" => "topic_id",
    )
  end

  it "preserves stable identity and mapping across label changes and equivalent reordering" do
    first = catalog
    first[:catalog][:containers] << {
      id: "archive", label: "Archive", kind: "collection", taxonomy_ids: ["post_tag"],
    }
    put "/discussion-bridge/v1/platform-catalog.json", params: first, headers: headers, as: :json
    initial_catalog_revision = response.parsed_body.fetch("catalog_revision")
    initial_display_revision = response.parsed_body.fetch("catalog_display_revision")
    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: { content_connection: { destination_mapping: {
          category_mappings: [{ source_category_id: category.id, destination_container_id: "post" }],
          tag_mappings: [], unmapped_category_policy: "hold", unmapped_tag_policy: "omit",
          presentation_mode: "native",
        } } }, as: :json
    initial_mapping_revision = @connection.reload.destination_mapping_revision

    second = catalog
    second[:catalog][:containers] = [
      { id: "post", label: "Articles", kind: "post_type", taxonomy_ids: ["post_tag"] },
      { id: "archive", label: "Archives", kind: "collection", taxonomy_ids: ["post_tag"] },
    ].reverse
    put "/discussion-bridge/v1/platform-catalog.json", params: second,
        headers: headers, as: :json

    expect(response.parsed_body.fetch("catalog_revision")).to eq(initial_catalog_revision)
    expect(response.parsed_body.fetch("catalog_display_revision")).not_to eq(initial_display_revision)
    expect(@connection.reload.destination_mapping_revision).to eq(initial_mapping_revision)
    expect(@connection.platform_catalog.dig("containers", 1, "label")).to eq("Articles")
  end

  it "invalidates a mapping when its stable destination id disappears" do
    put "/discussion-bridge/v1/platform-catalog.json", params: catalog, headers: headers, as: :json
    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: { content_connection: { destination_mapping: {
          category_mappings: [{ source_category_id: category.id, destination_container_id: "post" }],
          tag_mappings: [], unmapped_category_policy: "hold", unmapped_tag_policy: "omit",
          presentation_mode: "native",
        } } }, as: :json
    replacement = catalog
    replacement[:catalog][:containers] = [{
      id: "page", label: "Pages", kind: "post_type", taxonomy_ids: ["post_tag"],
    }]

    put "/discussion-bridge/v1/platform-catalog.json", params: replacement,
        headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(@connection.reload.destination_mapping_revision).to be_nil
  end

  it "binds an adapter upgrade only when its catalog replacement succeeds" do
    put "/discussion-bridge/v1/platform-catalog.json", params: catalog, headers: headers, as: :json

    get "/discussion-bridge/v1/platform-catalog.json", headers: headers(version: "1.1.0")

    expect(response).to have_http_status(:ok)
    expect(@connection.reload.adapter_version).to eq("1.0.0")

    put "/discussion-bridge/v1/platform-catalog.json",
        params: catalog, headers: headers(version: "1.1.0"), as: :json

    expect(response).to have_http_status(:ok)
    expect(@connection.reload.adapter_version).to eq("1.1.0")
    expect(@connection.platform_catalog_adapter_version).to eq("1.1.0")
  end

  it "exposes the current catalog generation during an adapter upgrade without rebinding it" do
    put "/discussion-bridge/v1/platform-catalog.json", params: catalog, headers: headers, as: :json

    get "/discussion-bridge/v1/bridge-records.json", headers: headers(version: "1.1.0")
    expect(response).to have_http_status(:ok)

    get "/discussion-bridge/v1/platform-catalog.json", headers: headers(version: "1.1.0")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "catalog_adapter_version" => "1.0.0",
      "connection_adapter_version" => "1.0.0",
    )
    expect(@connection.reload.adapter_version).to eq("1.0.0")
  end

  it "rejects a stale catalog replacement without downgrading the current catalog" do
    put "/discussion-bridge/v1/platform-catalog.json", params: catalog, headers: headers, as: :json
    current_revision = @connection.reload.platform_catalog_revision
    replacement = catalog
    replacement[:expected_catalog_revision] = "0" * 64
    replacement[:catalog][:containers][0][:label] = "Stale replacement"

    put "/discussion-bridge/v1/platform-catalog.json", params: replacement, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("platform catalog changed; refresh before replacement")
    expect(@connection.reload.platform_catalog_revision).to eq(current_revision)
    expect(@connection.platform_catalog.dig("containers", 0, "label")).to eq("Posts")
  end

  it "keeps the maximum receiver-owned mapping inside the adapter status budget" do
    put "/discussion-bridge/v1/platform-catalog.json", params: catalog, headers: headers, as: :json
    category_mappings = 100.times.map do |index|
      {
        "source_category_id" => index + 1,
        "destination_container_id" => "container:#{index}:#{'c' * 180}",
      }
    end
    tag_mappings = 500.times.map do |index|
      {
        "source_tag_id" => index + 1,
        "destination_taxonomy_id" => "taxonomy:#{index}:#{'t' * 160}",
        "destination_term_id" => "term:#{index}:#{'v' * 180}",
      }
    end
    @connection.update_columns(
      destination_mapping: {
        "catalog_revision" => @connection.reload.platform_catalog_revision,
        "category_mappings" => category_mappings,
        "tag_mappings" => tag_mappings,
      },
      destination_mapping_revision: Digest::SHA256.hexdigest("maximum mapping"),
    )

    get "/discussion-bridge/v1/platform-catalog.json", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to be < 1024 * 1024
  end

  it "rejects missing and cyclic platform parents" do
    invalid = catalog
    invalid[:catalog][:containers] = [
      { id: "one", label: "One", kind: "section", parent_id: "two", taxonomy_ids: [] },
      { id: "two", label: "Two", kind: "section", parent_id: "one", taxonomy_ids: [] },
    ]

    put "/discussion-bridge/v1/platform-catalog.json", params: invalid,
        headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("cyclic container hierarchy")
  end

  it "rejects mappings whose taxonomy is unavailable on a mapped container" do
    candidate = catalog
    candidate[:catalog][:containers] = [{
      id: "page", label: "Page", kind: "post_type", taxonomy_ids: [],
    }]
    put "/discussion-bridge/v1/platform-catalog.json", params: candidate,
        headers: headers, as: :json
    sign_in(admin)

    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: { content_connection: { destination_mapping: {
          category_mappings: [{ source_category_id: category.id, destination_container_id: "page" }],
          tag_mappings: [{
            source_tag_id: tag.id, destination_taxonomy_id: "post_tag", destination_term_id: "policy",
          }],
          unmapped_category_policy: "hold", unmapped_tag_policy: "omit",
          presentation_mode: "native",
        } } }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include(
      "destination taxonomy is unsupported by a mapped container",
    )
  end

  it "rejects a destination plan without update and revocation capability" do
    candidate = catalog
    candidate[:catalog][:capabilities] = { updates: false, drafts: false, unpublish: false }
    put "/discussion-bridge/v1/platform-catalog.json", params: candidate,
        headers: headers, as: :json
    sign_in(admin)

    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: { content_connection: { destination_mapping: {
          category_mappings: [{ source_category_id: category.id, destination_container_id: "post" }],
          tag_mappings: [], unmapped_category_policy: "hold", unmapped_tag_policy: "omit",
          presentation_mode: "native",
        } } }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("platform does not support publication updates")
  end
end
