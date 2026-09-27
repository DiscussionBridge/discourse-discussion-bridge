# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge Adapter Protocol request boundary" do
  fab!(:service_actor, :admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = service_actor.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Boundary WordPress",
      platform: "wordpress",
      allowed_origins: ["https://example.com"],
      allowed_directions: %w[to_discourse from_discourse],
      allowed_lanes: ["articles"],
    )
  end

  def protocol_headers(correlation: "boundary-1", secret: @secret)
    {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => secret,
      "X-DiscussionBridge-Contract" => DiscussionBridge::CONTRACT_VERSION,
      "X-DiscussionBridge-Correlation" => correlation,
      "HTTPS" => "on",
    }
  end

  def protocol_payload(correlation: "boundary-1")
    content_html = "<p>Bounded request content.</p>"
    {
      bridge_record: {
        direction: "to_discourse",
        external_id: "boundary-post-1",
        canonical_url: "https://example.com/articles/boundary/",
        title: "Adapter request boundary",
        content_html: content_html,
        published: true,
        presentation_mode: "interactive",
        source_revision: "wordpress:boundary:revision:1",
        source_revision_sequence: 1,
        source_created_at: "2026-09-01T16:00:00Z",
        source_updated_at: "2026-09-27T18:30:00Z",
        content_disposition: "complete",
        source_content_bytes: content_html.bytesize,
        source_content_sha256: Digest::SHA256.hexdigest(content_html),
        visibility: "unlisted",
        lane: "articles",
        correlation_id: correlation,
      },
    }
  end

  def expect_error(code, status:, correlation: nil)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body.keys).to contain_exactly("error_code", "message", "correlation_id")
    expect(response.parsed_body.fetch("error_code")).to eq(code)
    expect(response.body.bytesize).to be <= DiscussionBridge::AdapterRequestBoundary::MAX_ERROR_JSON_BYTES
    if correlation
      expect(response.headers["X-DiscussionBridge-Correlation"]).to eq(correlation)
      expect(response.parsed_body.fetch("correlation_id")).to eq(correlation)
    else
      expect(response.headers["X-DiscussionBridge-Correlation"]).to eq(
        response.parsed_body.fetch("correlation_id"),
      )
      expect(response.parsed_body.fetch("correlation_id")).to be_present
    end
  end

  it "echoes the exact correlation identifier on successful reads and writes" do
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: protocol_headers,
         params: protocol_payload,
         as: :json

    expect(response).to have_http_status(:created), response.body
    expect(response.headers["X-DiscussionBridge-Correlation"]).to eq("boundary-1")
    expect(response.parsed_body.fetch("correlation_id")).to eq("boundary-1")

    get "/discussion-bridge/v1/bridge-records.json",
        headers: protocol_headers(correlation: "boundary-read-1")
    expect(response).to have_http_status(:ok)
    expect(response.headers["X-DiscussionBridge-Correlation"]).to eq("boundary-read-1")
    expect(response.parsed_body.fetch("correlation_id")).to eq("boundary-read-1")
  end

  it "rejects a missing or wrong contract version before authentication state changes" do
    missing = protocol_headers.except("X-DiscussionBridge-Contract")
    get "/discussion-bridge/v1/bridge-records.json", headers: missing
    expect_error("contract_version_mismatch", status: :unauthorized, correlation: "boundary-1")

    wrong = protocol_headers.merge("X-DiscussionBridge-Contract" => "0.2.0-alpha.20")
    get "/discussion-bridge/v1/bridge-records.json", headers: wrong
    expect_error("contract_version_mismatch", status: :unauthorized, correlation: "boundary-1")
    expect(@connection.reload.last_seen_at).to be_nil
  end

  it "generates one safe response correlation when the request correlation is missing or invalid" do
    get "/discussion-bridge/v1/bridge-records.json",
        headers: protocol_headers.except("X-DiscussionBridge-Correlation")
    expect_error("validation_failed", status: :unprocessable_entity)

    get "/discussion-bridge/v1/bridge-records.json",
        headers: protocol_headers(correlation: "a" * 201)
    expect_error("validation_failed", status: :unprocessable_entity)
    expect(@connection.reload.last_seen_at).to be_nil
  end

  it "rejects body/header correlation mismatch before mutation" do
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: protocol_headers,
         params: protocol_payload(correlation: "other-request"),
         as: :json

    expect_error("validation_failed", status: :unprocessable_entity, correlation: "boundary-1")
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(@connection.reload.last_seen_at).to be_nil
  end

  it "uses Content Connection credentials as the only authentication authority" do
    exposed_secret = "wrong-secret-that-is-long-enough-to-test"
    get "/discussion-bridge/v1/bridge-records.json",
        headers: protocol_headers(secret: exposed_secret).merge(
          "X-DiscussionBridge-Adapter" => @connection.public_id,
          "X-DiscussionBridge-Adapter-Version" => "999.0.0",
        )

    expect_error("authentication_failed", status: :unauthorized, correlation: "boundary-1")
    expect(response.body).not_to include(exposed_secret)
    expect(response.body).not_to include(@secret)
    expect(@connection.reload.last_seen_at).to be_nil
  end

  it "requires the configured canonical HTTPS service origin" do
    get "/discussion-bridge/v1/bridge-records.json",
        headers: protocol_headers.except("HTTPS")

    expect_error("policy_denied", status: :forbidden, correlation: "boundary-1")
    expect(@connection.reload.last_seen_at).to be_nil
  end

  it "requires JSON and rejects malformed JSON before authentication state changes" do
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: protocol_headers.merge("CONTENT_TYPE" => "text/plain"),
         params: JSON.generate(protocol_payload)
    expect_error("unsupported_media_type", status: :unsupported_media_type, correlation: "boundary-1")

    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: protocol_headers.merge("CONTENT_TYPE" => "application/json"),
         params: "{not-json"
    expect_error("invalid_json", status: :bad_request, correlation: "boundary-1")
    expect(@connection.reload.last_seen_at).to be_nil
  end

  it "rejects unknown request fields and oversized bodies before mutation" do
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: protocol_headers,
         params: protocol_payload.merge(unexpected_control: "expand_scope"),
         as: :json
    expect_error("unknown_field", status: :bad_request, correlation: "boundary-1")

    nested_unknown = protocol_payload
    nested_unknown[:bridge_record][:unexpected_control] = "expand_scope"
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: protocol_headers,
         params: nested_unknown,
         as: :json
    expect_error("unknown_field", status: :bad_request, correlation: "boundary-1")

    author_unknown = protocol_payload
    author_unknown[:bridge_record].merge!(
      source_authors: [{ id: "author-1", name: "Editor", unexpected_control: true }],
      primary_source_author_id: "author-1",
    )
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: protocol_headers,
         params: author_unknown,
         as: :json
    expect_error("unknown_field", status: :bad_request, correlation: "boundary-1")

    oversized = protocol_payload
    oversized[:bridge_record][:content_html] = "x" * (64 * 1024)
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: protocol_headers,
         params: oversized,
         as: :json
    expect_error("request_too_large", status: :payload_too_large, correlation: "boundary-1")

    get "/discussion-bridge/v1/bridge-records.json?unexpected=true", headers: protocol_headers
    expect_error("unknown_field", status: :bad_request, correlation: "boundary-1")
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(@connection.reload.last_seen_at).to be_nil
  end
end
