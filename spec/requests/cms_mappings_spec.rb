# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsMappingsController do
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
        name: "CMS mapping HTTP fixture",
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
      },
    }
    @connection.update!(cms_configuration: @configuration)
    @headers = {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
      "CONTENT_TYPE" => "application/json",
    }
  end

  def receive_source
    store = DiscussionBridge::CmsSourceStore.new(@connection)
    store.refresh_topic!(topic.id)
    store.intent("topic:#{topic.id}").current_source_revision
  end

  def prepare_input(revision = receive_source)
    {
      "mutation_id" => SecureRandom.uuid,
      "source_id" => "topic:#{topic.id}",
      "source_revision" => revision,
      "policy_revision" => @configuration.dig("policy", "policy_revision"),
      "external_id" => " article/opaque ",
      "canonical_url" => "https://site.example/article/?x=%2f&y=1",
    }
  end

  def post_prepare(input, headers: @headers)
    post "/discussion-bridge/v2/mappings/prepare.json",
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
  end

  it "checks malformed syntax before credentials and typed unknown fields after credentials" do
    get "/discussion-bridge/v2/mappings.json?cursor=x&cursor=y"
    protocol_error("invalid_field", :unprocessable_entity)
    get "/discussion-bridge/v2/mappings.json?unknown=1"
    protocol_error("authentication_required", :unauthorized)
    get "/discussion-bridge/v2/mappings.json?unknown=1", headers: @headers
    protocol_error("unknown_field", :bad_request)
    get "/discussion-bridge/v2/mappings.json",
        headers: @headers,
        env: {
          "rack.input" => StringIO.new("{}"),
          "CONTENT_LENGTH" => "2",
        }
    protocol_error("invalid_field", :unprocessable_entity)
    post "/discussion-bridge/v2/mappings/prepare.json", params: "{", headers: @headers
    protocol_error("invalid_json", :bad_request)
  end

  it "does not admit a source or create a record/work from a caller prepare or inventory" do
    get "/discussion-bridge/v2/mappings.json", headers: @headers
    expect(response.parsed_body).to eq("items" => [], "next_cursor" => nil)
    post_prepare(prepare_input("undiscovered"))
    protocol_error("native_service_unavailable", :service_unavailable)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "prepares once, replays the accepted receipt and exposes owned pending metadata without secrets" do
    input = prepare_input
    native_counts = [Topic.count, Post.count]
    post_prepare(input)
    expect(response).to have_http_status(:created)
    accepted = response.parsed_body
    DiscussionBridge::CmsProtocol.validate!("Mapping", accepted)
    expect(accepted.fetch("canonical_url")).to eq(input.fetch("canonical_url"))
    expect(accepted.fetch("external_id")).to eq(input.fetch("external_id"))
    expect(accepted.fetch("destination_native_id")).to be_nil
    expect(accepted.fetch("mapping_state")).to eq("pending")
    post_prepare(input)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to eq(accepted)
    post_prepare(input.merge("mutation_id" => SecureRandom.uuid))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(accepted)
    get "/discussion-bridge/v2/mappings/#{accepted.fetch("mapping_id")}.json", headers: @headers
    expect(response.parsed_body).to eq(accepted)
    expect(response.body.include?(@secret)).to eq(false)
    expect(response.body.include?("lease_token")).to eq(false)
    get "/discussion-bridge/v2/mappings.json", headers: @headers
    expect(response.parsed_body).to eq("items" => [accepted], "next_cursor" => nil)
    get "/discussion-bridge/v2/mappings/#{accepted.fetch("mapping_id")}/url-history.json",
        headers: @headers
    expect(response.parsed_body).to eq("items" => [], "next_cursor" => nil)
    expect([Topic.count, Post.count]).to eq(native_counts)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
    expect(DiscussionBridgeCmsWork.count).to eq(1)
  end

  it "rejects changed mutation identity and preserves an off-policy owned status" do
    input = prepare_input
    post_prepare(input)
    mapping_id = response.parsed_body.fetch("mapping_id")
    post_prepare(input.merge("external_id" => "changed"))
    protocol_error("mutation_conflict", :conflict)
    @configuration.fetch("policy")["enabled"] = false
    @connection.update!(cms_configuration: @configuration)
    get "/discussion-bridge/v2/mappings/#{mapping_id}.json", headers: @headers
    expect(response).to have_http_status(:ok)
    post_prepare(input.merge("mutation_id" => SecureRandom.uuid))
    protocol_error("scope_denied", :forbidden)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end

  it "requires explicit owned baseline adoption and preserves the native source and existing binding" do
    receive_source
    record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: topic.id,
        external_id: "baseline",
        canonical_url: "https://site.example/baseline/",
        lane: "news",
      ).record
    binding = record.active_binding("presentation")
    preserved = [
      record.attributes,
      binding.attributes,
      topic.reload.attributes,
      first_post.reload.attributes,
    ]
    input = {
      "mutation_id" => SecureRandom.uuid,
      "resource_id" => record.resource_id,
      "source_id" => "topic:#{topic.id}",
      "expected_topic_id" => topic.id.to_s,
      "ownership" => {
        "resource_id" => record.resource_id,
        "external_id" => binding.external_id,
        "native_id" => "native:owned-baseline",
        "canonical_url" => binding.canonical_url,
        "source_revision" => nil,
        "ownership_receipt_sha256" => "a" * 64,
      },
    }
    post "/discussion-bridge/v2/mappings/adopt.json",
         params: JSON.generate(input),
         headers: @headers
    protocol_error("scope_denied", :forbidden)
    @configuration.fetch("policy").merge!(
      "existing_record_adoption" => "explicit_records_only",
      "adoptable_resource_ids" => [record.resource_id],
    )
    @connection.update!(cms_configuration: @configuration)
    # The receiver explicitly refreshes under the updated policy.
    receive_source
    post "/discussion-bridge/v2/mappings/adopt.json",
         params: JSON.generate(input),
         headers: @headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("destination_native_id")).to eq("native:owned-baseline")
    expect(response.parsed_body.fetch("synchronized_source_revision")).to be_nil
    expect(response.parsed_body.fetch("publicly_verified_source_revision")).to be_nil
    expect(
      [
        record.reload.attributes,
        binding.reload.attributes,
        topic.reload.attributes,
        first_post.reload.attributes,
      ],
    ).to eq(preserved)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end

  it "rejects foreign UUIDs and rechecks credential rotation for every read" do
    input = prepare_input
    post_prepare(input)
    mapping_id = response.parsed_body.fetch("mapping_id")
    get "/discussion-bridge/v2/mappings/#{SecureRandom.uuid}/url-history.json", headers: @headers
    protocol_error("resource_not_found", :not_found)
    @connection.rotate_secret!
    get "/discussion-bridge/v2/mappings/#{mapping_id}.json", headers: @headers
    protocol_error("authentication_failed", :unauthorized)
    expect(DiscussionBridgeCmsWork.count).to eq(1)
  end
end
