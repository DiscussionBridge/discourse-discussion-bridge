# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsWorkController do
  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS request fixture",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @headers = {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
      "CONTENT_TYPE" => "application/json",
    }
    @policy = {
      "policy_revision" => SecureRandom.uuid,
      "enabled" => true,
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
    }
    @connection.update!(
      cms_configuration: {
        "profile" => "ghost",
        "destination_origin" => "https://site.example",
        "publication_lane" => "news",
        "policy" => @policy,
        "native_capabilities" => {
          "native_revision" => "ghost:fixture",
          "supported_presentations" => ["simple"],
          "publication_kind" => "dynamic",
          "complete_content_supported" => true,
        },
      },
    )
  end

  def post_claim(input = { "mutation_id" => SecureRandom.uuid }, headers: @headers, query: "")
    post "/discussion-bridge/v2/work/claim.json#{query}",
         params: JSON.generate(input),
         headers: headers
  end

  def expect_error(code, status)
    expect(response).to have_http_status(status)
    expect(response.parsed_body).to eq(
      "outcome" => "rejected",
      "code" => code,
      "retryable" => false,
      "retry_after_seconds" => nil,
      "correlation_id" => nil,
      "core_fallback" => false,
    )
  end

  def create_work
    user = Fabricate(:user)
    topic = Fabricate(:topic, user: user)
    post = Fabricate(:post, topic: topic, user: user, post_number: 1)
    record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: user,
        connection_id: @connection.id,
        topic_id: topic.id,
        external_id: "article",
        canonical_url: "https://site.example/article/",
        lane: "news",
        native_materialization: true,
        presentation_mode: "simple",
      ).record
    mapping =
      DiscussionBridgeCmsMapping.create!(
        mapping_id: SecureRandom.uuid,
        content_connection: @connection,
        content_binding: record.active_binding("presentation"),
        source_id: "topic:#{topic.id}",
        mapping_revision: SecureRandom.uuid,
      )
    source = DiscussionBridge::CmsSourceStore.new(@connection).capture_snapshot(topic).metadata
    DiscussionBridge::CmsWorkCoordinator.new(@connection).enqueue!(mapping, source_snapshot: source)
  end

  it "authenticates after syntax checks, before typed fields and resource lookup" do
    post_claim(headers: { "CONTENT_TYPE" => "application/json" }, query: "?x=1")
    expect_error("authentication_required", :unauthorized)
    post_claim({ "mutation_id" => "invalid" }, headers: { "CONTENT_TYPE" => "application/json" })
    expect_error("authentication_required", :unauthorized)
    post "/discussion-bridge/v2/work/claim.json",
         params: '{"mutation_id":',
         headers: {
           "CONTENT_TYPE" => "application/json",
         }
    expect_error("invalid_json", :bad_request)
  end

  it "distinguishes invalid credentials and disabled connections without granting publishing scope" do
    post_claim(headers: @headers.merge("X-DiscussionBridge-Secret" => "x" * 43))
    expect_error("authentication_failed", :unauthorized)
    @connection.update!(enabled: false)
    post_claim
    expect_error("connection_disabled", :forbidden)
    expect(DiscussionBridgeCmsMutationReceipt.count).to eq(0)
  end

  it "keeps typed negative-zero checks after authentication and rejects malformed bytes at the scoped guard" do
    input = '{"mutation_id":"11111111-1111-4111-8111-000000000001","attempt":-0}'
    post "/discussion-bridge/v2/work/claim.json",
         params: input,
         headers: {
           "CONTENT_TYPE" => "application/json",
         }
    expect_error("authentication_required", :unauthorized)
    post "/discussion-bridge/v2/work/claim.json", params: input, headers: @headers
    expect_error("unknown_field", :bad_request)
    post "/discussion-bridge/v2/work/claim.json", params: "\uFEFF{}", headers: @headers
    expect_error("invalid_json", :bad_request)
    post "/discussion-bridge/v2/work/claim.json", params: " " * 65_537, headers: @headers
    expect_error("body_too_large", :payload_too_large)
  end

  it "requires an explicit current CMS configuration and enabled publisher policy" do
    @connection.update!(cms_configuration: nil)
    post_claim
    expect_error("scope_denied", :forbidden)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "rejects duplicate keys, unknown fields, query duplicates, compressed requests and wrong media" do
    post "/discussion-bridge/v2/work/claim.json",
         params: '{"mutation_id":"a","mutation_id":"b"}',
         headers: @headers
    expect_error("invalid_json", :bad_request)
    post_claim({ "mutation_id" => SecureRandom.uuid, "new_source" => true })
    expect_error("unknown_field", :bad_request)
    post_claim(query: "?x=1&x=2")
    expect_error("invalid_field", :unprocessable_entity)
    post_claim(query: "?x=1")
    expect_error("unknown_field", :bad_request)
    post_claim(headers: @headers.merge("Content-Encoding" => "gzip"))
    expect_error("unsupported_media_type", :unsupported_media_type)
    post_claim(headers: @headers.merge("CONTENT_TYPE" => "text/plain"))
    expect_error("unsupported_media_type", :unsupported_media_type)
    expect(DiscussionBridgeCmsMutationReceipt.count).to eq(0)
  end

  it "replays exact no-work polls and never creates work from a mapping filter" do
    input = { "mutation_id" => SecureRandom.uuid, "mapping_id" => SecureRandom.uuid }
    post_claim(input)
    expect(response).to have_http_status(:no_content)
    expect(response.body).to eq("")
    post_claim(input)
    expect(response).to have_http_status(:no_content)
    expect(DiscussionBridgeCmsMutationReceipt.count).to eq(1)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "returns a real lease and token-free current status through the native HTTP routes" do
    work = create_work
    input = { "mutation_id" => SecureRandom.uuid }
    post_claim(input)
    expect(response).to have_http_status(:ok)
    lease = response.parsed_body
    DiscussionBridge::CmsProtocol.validate!("Lease", lease)
    expect(lease.fetch("work").fetch("work_id")).to eq(work.work_id)
    post_claim(input)
    expect(response.parsed_body).to eq(lease)
    get "/discussion-bridge/v2/work/#{work.work_id}.json", headers: @headers.except("CONTENT_TYPE")
    expect(response).to have_http_status(:ok)
    DiscussionBridge::CmsProtocol.validate!("WorkQueryResponse", response.parsed_body)
    expect(response.body).not_to include(lease.fetch("lease_token"), "lease_token")
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "revokes old credentials even for a previously accepted identical claim" do
    input = { "mutation_id" => SecureRandom.uuid }
    post_claim(input)
    expect(response).to have_http_status(:no_content)
    @connection.rotate_secret!
    post_claim(input)
    expect_error("authentication_failed", :unauthorized)
  end
end
