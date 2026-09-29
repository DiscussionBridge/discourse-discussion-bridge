# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::NetworkReceiver do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @original_forum_name = ENV["DISCUSSIONBRIDGE_FORUM_NAME"]
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "Regional Chapter"
    @identity = DiscussionBridgeForumIdentity.enable!(actor: admin)
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "National network source",
      platform: "discourse",
      allowed_origins: ["https://national.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: [],
      default_category_id: category.id,
      destination_policies: [destination_policy],
      policy_revision: "policy:2026-09-27:1",
      network_enabled: true,
      network_peer_forum_id: "dbf_11111111111111111111111111111111",
      network_relationship: "hub_to_spoke",
    )
    @peer = DiscussionBridgeNetworkPeer.create!(
      content_connection: @connection,
      name: "National Organization",
      remote_forum_id: "dbf_11111111111111111111111111111111",
      remote_forum_name: "National Organization",
      remote_origin: "https://national.example",
      remote_connection_id: "dbc_#{"1" * 24}",
      remote_secret: "s" * 32,
      relationship: "hub_to_spoke",
      enabled: true,
      authorized_by: admin,
      authorized_at: Time.zone.now,
    )
  end

  after { ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = @original_forum_name }

  def destination_policy
    {
      "destination_policy_id" => "destination:discourse:network:1",
      "profile" => "discourse_as_publisher",
      "presentation_mode" => "interactive",
      "container_mapping" => {
        "source" => "discourse:category:national",
        "destination" => "discourse:category:network",
      },
      "taxonomy_mapping" => { "mode" => "mapped_only" },
      "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => {
        "maximum_bytes" => 49_152,
        "overflow_behavior" => "excerpt_with_read_more",
      },
      "catalog_revision" => "catalog:discourse:2026-09-27:1",
    }
  end

  def source_detail
    JSON.parse(
      File.read(
        File.expand_path("../fixtures/network-source-detail.json", __dir__),
      ),
    )
  end

  it "creates one stable local topic, renders its boundary, and replays without mutation" do
    result = described_class.call(
      peer: @peer,
      source_detail: source_detail,
      policy_revision: "policy:2026-09-27:1",
    )
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: result.fetch("resource_id"))
    first_post = record.topic.first_post

    expect(result.fetch("outcome")).to eq("created")
    expect(result.fetch("route_forum_ids")).to eq([@peer.remote_forum_id, @identity.forum_id])
    expect(record.network_provenance.fetch("managed_scope")).to eq("first_post")
    expect(first_post.cooked).to include("National Organization")
    expect(first_post.cooked).to include("Regional Chapter")
    expect(first_post.cooked).to include("Replies and moderation remain local")
    original_version = first_post.version

    replay = described_class.call(
      peer: @peer,
      source_detail: source_detail,
      policy_revision: "policy:2026-09-27:1",
    )
    expect(replay.fetch("mutated")).to eq(false)
    expect(record.topic.first_post.reload.version).to eq(original_version)
    expect(DiscussionBridgeNetworkReplay.count).to eq(1)
  end

  it "rejects a changed operation replay without changing the local first post" do
    described_class.call(
      peer: @peer,
      source_detail: source_detail,
      policy_revision: "policy:2026-09-27:1",
    )
    record = DiscussionBridgeBridgeRecord.last
    original = record.topic.first_post.cooked
    changed = source_detail
    changed["source_revision"] = "post:501:version:3"

    expect do
      described_class.call(
        peer: @peer,
        source_detail: changed,
        policy_revision: "policy:2026-09-27:1",
      )
    end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) do |error|
      expect(error.error_code).to eq("operation_replay_mismatch")
    end
    expect(record.topic.first_post.reload.cooked).to eq(original)
  end

  it "updates the same first post while preserving local discussion" do
    created = described_class.call(
      peer: @peer,
      source_detail: source_detail,
      policy_revision: "policy:2026-09-27:1",
    )
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: created.fetch("resource_id"))
    topic = record.topic
    reply = Fabricate(:post, topic: topic, user: admin, post_number: 2, raw: "Local chapter reply")
    original_topic_id = topic.id
    original_reply_id = reply.id

    revised = source_detail
    revised_body = "<p>Revised national publication.</p>"
    revised["source_revision"] = "post:501:version:3"
    revised["source_revision_sequence"] = 3
    revised["source_updated_at"] = 1.minute.from_now.iso8601(6)
    revised["content_transport"]["byte_length"] = revised_body.bytesize
    revised["content_transport"]["sha256"] = Digest::SHA256.hexdigest(revised_body)
    revised["content_transport"]["content_html"] = revised_body
    revised["network_provenance"]["operation_id"] = "dbo_#{"2" * 32}"

    result = described_class.call(
      peer: @peer,
      source_detail: revised,
      policy_revision: "policy:2026-09-27:1",
    )

    expect(result).to include("outcome" => "resolved", "mutated" => true, "topic_id" => original_topic_id)
    expect(topic.first_post.reload.cooked).to include("Revised national publication")
    expect(topic.posts.find(original_reply_id).raw).to eq("Local chapter reply")
    expect(DiscussionBridgeBridgeRecord.where(resource_id: record.resource_id).count).to eq(1)
  end

  it "bounds escaped oversized content and links back to the source" do
    oversized = source_detail
    oversized_body = "<p>#{"&" * 60_000}</p>"
    oversized["content_transport"]["byte_length"] = oversized_body.bytesize
    oversized["content_transport"]["sha256"] = Digest::SHA256.hexdigest(oversized_body)
    oversized["content_transport"]["content_html"] = oversized_body

    result = described_class.call(
      peer: @peer,
      source_detail: oversized,
      policy_revision: "policy:2026-09-27:1",
    )
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: result.fetch("resource_id"))
    first_post = record.topic.first_post

    expect(record.content_disposition).to eq("excerpt")
    expect(first_post.raw.bytesize).to be <= 49_152
    expect(first_post.raw.length).to be <= SiteSetting.max_post_length
    expect(first_post.cooked).to include("Read More")
    expect(first_post.cooked).to include("This is an excerpt.")
    expect(first_post.cooked).to include(oversized.fetch("topic_url"))
    expect(record.source_content_bytes).to eq(oversized_body.bytesize)
  end

  it "keeps multibyte overflow inside native limits and the excerpt grammar" do
    detail = source_detail
    body = "<p>#{"漢" * 20_000}</p>"
    detail["content_transport"].merge!(
      "byte_length" => body.bytesize,
      "sha256" => Digest::SHA256.hexdigest(body),
      "content_html" => body,
    )
    parsed = DiscussionBridge::NetworkSourceDetail.call(payload: detail)
    receiver = described_class.new(
      peer: @peer,
      source_detail: detail,
      policy_revision: "policy:2026-09-27:1",
      content_html: nil,
    )
    output = receiver.send(
      :content_for_destination,
      parsed,
      parsed.fetch("network_provenance"),
      @connection,
    )
    expect(
      DiscussionBridge::BridgeRecordRequest.send(
        :valid_excerpt_markup?,
        output.fetch(:content_html),
        output.fetch(:read_more_url),
      ),
    ).to be(true)
    expect(output.fetch(:content_html).bytesize).to be <= 49_152
  end

  it "preserves the exact network source timestamp wire value" do
    detail = source_detail
    timestamp = "2026-09-27T18:00:00.123456789Z"
    detail["source_created_at"] = timestamp
    detail["source_updated_at"] = timestamp
    result = described_class.call(
      peer: @peer,
      source_detail: detail,
      policy_revision: "policy:2026-09-27:1",
    )
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: result.fetch("resource_id"))
    expect(record.source_created_at_wire).to eq(timestamp)
    expect(record.source_updated_at_wire).to eq(timestamp)
  end
end
