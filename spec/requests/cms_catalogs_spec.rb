# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsCatalogController do
  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS catalog HTTP fixture",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @configuration = {
      "profile" => "ghost",
      "destination_origin" => "https://site.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "native:fixture",
        "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic",
        "complete_content_supported" => true,
      },
      "policy" => {
        "policy_revision" => SecureRandom.uuid,
        "enabled" => false,
        "selection" => "all_public",
        "category_ids" => [],
        "include_topic_ids" => [],
        "exclude_topic_ids" => [],
        "include_unlisted" => false,
        "publication_kind" => "dynamic",
        "presentation_mode" => "simple",
        "author_ids" => [],
        "taxonomy_ids" => [],
        "existing_record_adoption" => "disabled",
        "adoptable_resource_ids" => [],
      },
    }
    @connection.update!(cms_configuration: @configuration)
    @headers = {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
      "CONTENT_TYPE" => "application/json",
    }
  end

  def begin_input(total = 0)
    {
      "mutation_id" => SecureRandom.uuid,
      "kind" => "authors",
      "native_revision" => "native-r1",
      "total_items" => total,
    }
  end

  def post_begin(input, headers: @headers)
    post "/discussion-bridge/v2/catalog/uploads.json",
         params: JSON.generate(input),
         headers: headers
  end

  def protocol_error(code, status)
    expect(response).to have_http_status(status)
    expect(response.parsed_body).to include(
      "outcome" => "rejected",
      "code" => code,
      "core_fallback" => false,
    )
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    expect(response.body.include?(@secret)).to eq(false)
  end

  it "checks transport syntax before auth and unknown semantic query fields after auth" do
    get "/discussion-bridge/v2/catalog.json?kind=authors&kind=taxonomy"
    protocol_error("invalid_field", :unprocessable_entity)
    get "/discussion-bridge/v2/catalog.json?unknown=1"
    protocol_error("authentication_required", :unauthorized)
    get "/discussion-bridge/v2/catalog.json?kind=authors&unknown=1", headers: @headers
    protocol_error("unknown_field", :bad_request)
    get "/discussion-bridge/v2/catalog.json?kind=authors",
        headers: @headers,
        env: {
          "rack.input" => StringIO.new("{}"),
          "CONTENT_LENGTH" => "2",
        }
    protocol_error("invalid_field", :unprocessable_entity)
    post "/discussion-bridge/v2/catalog/uploads.json", params: "{", headers: @headers
    protocol_error("invalid_json", :bad_request)
  end

  it "strictly rejects media, unknown keys, required query omission and unsafe integer spellings" do
    post_begin(begin_input, headers: @headers.merge("CONTENT_TYPE" => "text/plain"))
    protocol_error("unsupported_media_type", :unsupported_media_type)
    post_begin(begin_input.merge("enable_publication" => true))
    protocol_error("unknown_field", :bad_request)
    get "/discussion-bridge/v2/catalog.json", headers: @headers
    protocol_error("invalid_field", :unprocessable_entity)
    raw = JSON.generate(begin_input).sub('"total_items":0', '"total_items":9007199254740992')
    post "/discussion-bridge/v2/catalog/uploads.json", params: raw, headers: @headers
    protocol_error("invalid_field", :unprocessable_entity)
    raw = JSON.generate(begin_input).sub('"total_items":0', '"total_items":-0')
    post "/discussion-bridge/v2/catalog/uploads.json", params: raw, headers: @headers
    protocol_error("invalid_field", :unprocessable_entity)
    expect(DiscussionBridgeCmsCatalogUpload.count).to eq(0)
  end

  it "accepts and replays zero catalog operations with exact typed private no-store responses" do
    input = begin_input
    post_begin(input)
    expect(response).to have_http_status(:created)
    first = response.parsed_body
    DiscussionBridge::CmsProtocol.validate!("CatalogUpload", first)
    post_begin(input)
    expect(response.parsed_body).to eq(first)
    upload = first.fetch("upload_id")
    finish = {
      "mutation_id" => SecureRandom.uuid,
      "upload_id" => upload,
      "expected_total_items" => 0,
    }
    path = "/discussion-bridge/v2/catalog/uploads/#{upload}/finalize.json"
    post path, params: JSON.generate(finish), headers: @headers
    expect(response).to have_http_status(:ok)
    accepted = response.parsed_body
    DiscussionBridge::CmsProtocol.validate!("CatalogResponse", accepted)
    expect(accepted).to include("items" => [], "total_items" => 0, "next_cursor" => nil)
    post path, params: JSON.generate(finish), headers: @headers
    expect(response.parsed_body).to eq(accepted)
    get "/discussion-bridge/v2/catalog.json?kind=authors", headers: @headers
    expect(response.parsed_body).to eq(accepted)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.body.include?(@secret)).to eq(false)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(@connection.reload.cms_configuration).to eq(@configuration)
  end

  it "bounds the actual accepted raw UTF-8 page body before storing native metadata" do
    post_begin(begin_input(100))
    upload = response.parsed_body.fetch("upload_id")
    items =
      100.times.map do |index|
        { "id" => "#{index}#{'"' * 249}", "label" => '"' * 200, "available" => true }
      end
    body = JSON.generate("mutation_id" => SecureRandom.uuid, "page" => 0, "items" => items)
    expect(body.bytesize).to be > 65_536
    post "/discussion-bridge/v2/catalog/uploads/#{upload}/pages.json",
         params: body,
         headers: @headers
    protocol_error("body_too_large", :payload_too_large)
    expect(DiscussionBridgeCmsCatalogEntry.count).to eq(0)
    expect(DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload).received_items).to eq(0)
  end

  it "accepts bounded sequential native metadata pages and prevents duplicate IDs across pages" do
    post_begin(begin_input(2))
    upload = response.parsed_body.fetch("upload_id")
    path = "/discussion-bridge/v2/catalog/uploads/#{upload}/pages.json"
    first = {
      "mutation_id" => SecureRandom.uuid,
      "page" => 0,
      "items" => [{ "id" => " native:1 ", "label" => "Native one", "available" => true }],
    }
    post path, params: JSON.generate(first), headers: @headers
    expect(response).to have_http_status(:ok)
    post path,
         params: JSON.generate(first.merge("mutation_id" => SecureRandom.uuid, "page" => 1)),
         headers: @headers
    protocol_error("catalog_page_conflict", :conflict)
    second = {
      "mutation_id" => SecureRandom.uuid,
      "page" => 1,
      "items" => [{ "id" => "native:2", "label" => "Native two", "available" => false }],
    }
    post path, params: JSON.generate(second), headers: @headers
    expect(response.parsed_body.fetch("received_items")).to eq(2)
    finish = {
      "mutation_id" => SecureRandom.uuid,
      "upload_id" => upload,
      "expected_total_items" => 2,
    }
    post "/discussion-bridge/v2/catalog/uploads/#{upload}/finalize.json",
         params: JSON.generate(finish),
         headers: @headers
    expect(response.parsed_body.fetch("items")).to eq(first.fetch("items") + second.fetch("items"))
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "checks path identity and cross-connection upload scope without protected owner disclosure" do
    post_begin(begin_input)
    upload = response.parsed_body.fetch("upload_id")
    finish = {
      "mutation_id" => SecureRandom.uuid,
      "upload_id" => SecureRandom.uuid,
      "expected_total_items" => 0,
    }
    path = "/discussion-bridge/v2/catalog/uploads/#{upload}/finalize.json"
    post path, params: JSON.generate(finish), headers: @headers
    protocol_error("identity_conflict", :conflict)
    other, other_secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Other HTTP catalog",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    other.update!(cms_configuration: @configuration.deep_dup)
    other_headers =
      @headers.merge(
        "X-DiscussionBridge-Connection" => other.public_id,
        "X-DiscussionBridge-Secret" => other_secret,
      )
    post path, params: JSON.generate(finish.merge("upload_id" => upload)), headers: other_headers
    protocol_error("resource_not_found", :not_found)
    expect(response.body.include?(@connection.public_id)).to eq(false)
    expect(DiscussionBridgeCmsCatalogSnapshot.count).to eq(0)
  end

  it "denies a saved accepted begin replay immediately after credential rotation or disable" do
    input = begin_input
    post_begin(input)
    expect(response).to have_http_status(:created)
    fresh_secret = @connection.rotate_secret!
    post_begin(input)
    protocol_error("authentication_failed", :unauthorized)
    @connection.update!(enabled: false)
    get "/discussion-bridge/v2/catalog.json?kind=authors",
        headers: @headers.merge("X-DiscussionBridge-Secret" => fresh_secret)
    protocol_error("connection_disabled", :forbidden)
    expect(response.body.include?(fresh_secret)).to eq(false)
    expect(DiscussionBridgeCmsCatalogUpload.count).to eq(1)
  end
end
