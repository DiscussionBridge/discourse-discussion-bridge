# frozen_string_literal: true

require "rails_helper"
require "stringio"

describe "DiscussionBridge native CMS configuration and descriptors" do
  fab!(:admin)
  fab!(:user)
  fab!(:moderator)

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    # Native authentication cookies are secure when force_https is enabled.
    # Exercise the native session through HTTPS rather than weakening it.
    https!
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS HTTP authority fixture",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @api_headers = {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
    }
    @json_headers = { "CONTENT_TYPE" => "application/json" }
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
  end

  def admin_path
    "/discussion-bridge/admin/content-connections/#{@connection.id}/cms-configuration.json"
  end

  def configure(
    input = { "expected_policy_revision" => nil, "configuration" => @configuration },
    headers: @json_headers
  )
    put admin_path, params: JSON.generate(input), headers: headers
  end

  def audit_count
    DB.query_single("SELECT count(*) FROM discussion_bridge_cms_configuration_events").first.to_i
  end

  def protocol_error(code, status)
    expect(response).to have_http_status(status)
    expect(response.parsed_body.fetch("code")).to eq(code)
    expect(response.parsed_body.fetch("core_fallback")).to eq(false)
  end

  it "requires native administrator identity even when Content Connection credentials are supplied" do
    configure(headers: @json_headers.merge(@api_headers))
    expect(response).to have_http_status(:forbidden)
    [user, moderator].each do |actor|
      sign_in(actor)
      configure
      expect(response).to have_http_status(:forbidden)
    end
    expect(@connection.reload.cms_configuration).to eq(nil)
    expect(audit_count).to eq(0)
  end

  it "exposes native admin absent configuration without inventing defaults" do
    sign_in(admin)
    get admin_path
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("cms_configuration" => nil)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(audit_count).to eq(0)
  end

  it "writes native configuration once and returns receiver-issued exact policy revision" do
    sign_in(admin)
    configure
    expect(response).to have_http_status(:ok)
    stored = response.parsed_body.fetch("cms_configuration")
    DiscussionBridge::CmsProtocol.validate!("Policy", stored.fetch("policy"))
    expect(stored.fetch("policy").fetch("enabled")).to eq(false)
    expect(audit_count).to eq(1)
    get admin_path
    expect(response.parsed_body.fetch("cms_configuration")).to eq(stored)
    expect(response.body).not_to include(@secret, @connection.secret_digest)
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "refuses stale/native-unknown bodies and strict transport defects without changing configuration" do
    sign_in(admin)
    configure
    stored = @connection.reload.cms_configuration
    configure({ "expected_policy_revision" => "stale", "configuration" => @configuration })
    protocol_error("revision_conflict", :conflict)
    configure(
      {
        "expected_policy_revision" => stored.dig("policy", "policy_revision"),
        "configuration" => @configuration,
        "secret" => @secret,
      },
    )
    protocol_error("unknown_field", :bad_request)
    put admin_path, params: '{"configuration":{},"configuration":{}}', headers: @json_headers
    protocol_error("invalid_json", :bad_request)
    put admin_path, params: " " * 65_537, headers: @json_headers
    protocol_error("body_too_large", :payload_too_large)
    configure(headers: { "CONTENT_TYPE" => "text/plain" })
    protocol_error("unsupported_media_type", :unsupported_media_type)
    configure(headers: @json_headers.merge("Content-Encoding" => "gzip"))
    protocol_error("unsupported_media_type", :unsupported_media_type)
    expect(@connection.reload.cms_configuration).to eq(stored)
    expect(audit_count).to eq(1)
  end

  it "authenticates adapter descriptor reads and denies absent configuration/disabled credentials" do
    get "/discussion-bridge/v2/connection.json"
    protocol_error("authentication_required", :unauthorized)
    get "/discussion-bridge/v2/connection.json", headers: @api_headers
    protocol_error("scope_denied", :forbidden)
    sign_in(admin)
    configure
    @connection.update!(enabled: false)
    get "/discussion-bridge/v2/policy.json", headers: @api_headers
    protocol_error("connection_disabled", :forbidden)
  end

  it "returns validated actual connection and policy while publisher is off without source/work side effects" do
    sign_in(admin)
    configure
    SiteSetting.discussion_bridge_publisher_enabled = false
    get "/discussion-bridge/v2/connection.json", headers: @api_headers
    expect(response).to have_http_status(:ok)
    descriptor = response.parsed_body
    DiscussionBridge::CmsProtocol.validate!("Connection", descriptor)
    expect(descriptor.fetch("connection_id")).to eq(@connection.public_id)
    expect(descriptor.fetch("forum_name")).to eq(SiteSetting.title)
    expect(descriptor.fetch("directions")).to eq(["from_discourse"])
    expect(descriptor.fetch("native_capabilities")).to eq(
      @configuration.fetch("native_capabilities"),
    )
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.body).not_to include(@secret, @connection.secret_digest, "lease_token")
    get "/discussion-bridge/v2/policy.json", headers: @api_headers
    expect(response.parsed_body).to eq(descriptor.fetch("policy"))
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(audit_count).to eq(1)
  end

  it "supports explicit To-only descriptor configuration without authorizing publisher work" do
    @connection.update!(allowed_directions: ["to_discourse"])
    sign_in(admin)
    configure
    expect(response).to have_http_status(:ok)
    get "/discussion-bridge/v2/connection.json", headers: @api_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("directions")).to eq(["to_discourse"])
    get "/discussion-bridge/v2/policy.json", headers: @api_headers
    expect(response.parsed_body.fetch("enabled")).to eq(false)
    post "/discussion-bridge/v2/work/claim.json",
         params: JSON.generate("mutation_id" => SecureRandom.uuid),
         headers: @api_headers.merge(@json_headers)
    protocol_error("scope_denied", :forbidden)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "keeps descriptor query/GET-body boundaries and secret rotation fail closed" do
    sign_in(admin)
    configure
    get "/discussion-bridge/v2/connection.json?x=1&x=2", headers: @api_headers
    protocol_error("invalid_field", :unprocessable_entity)
    get "/discussion-bridge/v2/policy.json?x=1", headers: @api_headers
    protocol_error("unknown_field", :bad_request)
    get "/discussion-bridge/v2/policy.json",
        env: {
          "rack.input" => StringIO.new("{}"),
          "CONTENT_LENGTH" => "2",
        },
        headers: @api_headers.merge(@json_headers)
    protocol_error("invalid_field", :unprocessable_entity)
    @connection.rotate_secret!
    get "/discussion-bridge/v2/connection.json", headers: @api_headers
    protocol_error("authentication_failed", :unauthorized)
    expect(audit_count).to eq(1)
  end
end
