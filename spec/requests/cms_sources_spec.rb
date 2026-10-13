# frozen_string_literal: true

require "rails_helper"
require "base64"

describe DiscussionBridge::CmsSourcesController do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS source HTTP author fixture",
        platform: "hugo",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @connection.update!(
      cms_configuration: {
        "profile" => "hugo",
        "destination_origin" => "https://site.example",
        "publication_lane" => "news",
        "native_capabilities" => {
          "native_revision" => "native:fixture",
          "supported_presentations" => ["simple"],
          "publication_kind" => "static",
          "complete_content_supported" => true,
        },
        "policy" => {
          "policy_revision" => SecureRandom.uuid,
          "enabled" => true,
          "selection" => "all_public",
          "category_ids" => [],
          "include_topic_ids" => [],
          "exclude_topic_ids" => [],
          "include_unlisted" => false,
          "publication_kind" => "static",
          "presentation_mode" => "simple",
          "author_ids" => [],
          "taxonomy_ids" => [],
          "existing_record_adoption" => "disabled",
          "adoptable_resource_ids" => [],
        },
      },
    )
    @headers = {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
    }
    @store = DiscussionBridge::CmsSourceStore.new(@connection)
  end

  def error(code, status)
    expect(response).to have_http_status(status)
    expect(response.parsed_body.fetch("code")).to eq(code)
    expect(response.parsed_body.fetch("core_fallback")).to eq(false)
  end

  def source
    @store.refresh_all!
    @store.feed("stream" => "initial").body.fetch("items").first.fetch("source")
  end

  def content_url(snapshot)
    "/discussion-bridge/v2/sources/#{snapshot.fetch("source_id")}/revisions/#{snapshot.fetch("source_revision")}/content.json"
  end

  it "authenticates before typed fields while rejecting duplicate and malformed query bytes before authentication" do
    get "/discussion-bridge/v2/sources.json?stream=invalid&unexpected=1"
    error("authentication_required", :unauthorized)
    get "/discussion-bridge/v2/sources.json?stream=initial&stream=changes"
    error("invalid_field", :unprocessable_entity)
    get "/discussion-bridge/v2/sources.json?stream=%FF"
    error("invalid_field", :unprocessable_entity)
    get "/discussion-bridge/v2/sources.json?stream=initial&unexpected=1", headers: @headers
    error("unknown_field", :bad_request)
  end

  it "cannot discover publication sources or create work through an initial GET" do
    get "/discussion-bridge/v2/sources.json?stream=initial", headers: @headers
    error("native_service_unavailable", :service_unavailable)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "returns the receiver-captured feed without materializing Bridge Records or publication work" do
    captured = source
    get "/discussion-bridge/v2/sources.json?stream=initial", headers: @headers
    expect(response).to have_http_status(:ok)
    payload = response.parsed_body
    DiscussionBridge::CmsProtocol.validate!("SourceFeed", payload)
    expect(payload.fetch("items").first.fetch("source")).to eq(captured)
    expect(payload.fetch("checkpoint_cursor")).to be_present
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "serves every immutable body byte across UTF8-splitting chunks and accepts an empty end chunk" do
    body = "<p>#{"a" * 32_764}#{"🙂" * 9_000}</p>"
    first_post.update_columns(cooked: body)
    captured = source
    bytes = "".b
    offset = 0
    loop do
      get "#{content_url(captured)}?offset=#{offset}", headers: @headers
      expect(response).to have_http_status(:ok)
      chunk = response.parsed_body
      DiscussionBridge::CmsProtocol.validate!("ContentChunk", chunk)
      bytes << Base64.strict_decode64(chunk.fetch("content_base64"))
      break if chunk.fetch("next_offset").nil?
      offset = chunk.fetch("next_offset")
    end
    expect(bytes).to eq(body.b)
    expect(Digest::SHA256.hexdigest(bytes)).to eq(captured.fetch("content_sha256"))
    get "#{content_url(captured)}?offset=#{body.bytesize}", headers: @headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("content_base64")).to eq("")
    expect(response.parsed_body.fetch("next_offset")).to be_nil
    get "#{content_url(captured)}?offset=#{body.bytesize + 1}", headers: @headers
    error("invalid_field", :unprocessable_entity)
  end

  it "blocks captured body access immediately when the native forum requires login" do
    captured = source
    SiteSetting.login_required = true
    get content_url(captured), headers: @headers
    error("source_ineligible", :forbidden)
    expect(response.body).not_to include(first_post.cooked)
  end
end
