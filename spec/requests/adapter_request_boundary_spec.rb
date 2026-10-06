# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge reconciled request boundary" do
  before { SiteSetting.discussion_bridge_enabled = SiteSetting.discussion_bridge_endpoint_enabled = true }

  def headers(**extra)
    { "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "boundary-1",
      "HTTPS" => "on", "CONTENT_TYPE" => "application/json" }.merge(extra)
  end

  def check_error(code, status)
    expect(response).to have_http_status(status), response.body
    expect(response.parsed_body.keys).to contain_exactly("error_code", "message", "correlation_id")
    expect(response.parsed_body.fetch("error_code")).to eq(code)
    expect(response.headers["X-DiscussionBridge-Correlation"]).to eq(response.parsed_body.fetch("correlation_id"))
    expect(response.body.bytesize).to be <= 4096
  end

  it "rejects the wrong version before reading credentials or changing connection presence" do
    get "/discussion-bridge/v1/bridge-records.json", headers: headers("X-DiscussionBridge-Contract" => "0.2.0-alpha.20")
    check_error("contract_version_mismatch", :unauthorized)
  end

  it "rejects duplicate JSON fields, unknown envelope fields and over-bound bodies" do
    post "/discussion-bridge/v1/bridge-records/resolve.json", params: '{"bridge_record":{},"bridge_record":{}}', headers: headers
    check_error("invalid_json", :bad_request)
    post "/discussion-bridge/v1/bridge-records/resolve.json", params: '{"extra":{}}', headers: headers
    check_error("unknown_field", :bad_request)
    post "/discussion-bridge/v1/bridge-records/resolve.json", params: " " * 65_537, headers: headers
    check_error("request_too_large", :payload_too_large)
  end

  it "rejects unknown query keys and noncanonical request origins" do
    get "/discussion-bridge/v1/bridge-records.json?secret=do-not-reflect", headers: headers
    check_error("unknown_field", :bad_request)
    expect(response.body).not_to include("do-not-reflect")
    get "/discussion-bridge/v1/bridge-records.json", headers: headers("HTTPS" => "off")
    check_error("scope_denied", :forbidden)
  end

  it "supplies one safe correlation on malformed or absent request correlation" do
    get "/discussion-bridge/v1/bridge-records.json", headers: headers.except("X-DiscussionBridge-Correlation")
    check_error("validation_failed", :unprocessable_entity)
    expect(response.parsed_body.fetch("correlation_id")).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "fails closed with the protocol envelope when the plugin or endpoint is disabled" do
    SiteSetting.discussion_bridge_enabled = false
    get "/discussion-bridge/v1/bridge-records.json", headers: headers
    check_error("temporarily_unavailable", :service_unavailable)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = false
    get "/discussion-bridge/v1/bridge-records.json", headers: headers
    check_error("temporarily_unavailable", :service_unavailable)
  end
end
