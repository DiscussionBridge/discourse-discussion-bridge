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
      policy_revision: receiver_policy_revision,
      network_enabled: true,
      network_peer_forum_id: remote_forum_id,
      network_relationship: network_relationship,
    )
    @peer = DiscussionBridgeNetworkPeer.create!(
      content_connection: @connection,
      name: "National Organization",
      remote_forum_id: remote_forum_id,
      remote_forum_name: "National Organization",
      remote_origin: "https://national.example",
      remote_connection_id: "dbc_#{"1" * 24}",
      remote_secret: "s" * 32,
      relationship: network_relationship,
      enabled: true,
      authorized_by: admin,
      authorized_at: Time.zone.now,
    )
  end

  after { ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = @original_forum_name }

  def destination_policy
    DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
      peer_forum_id: remote_forum_id,
      relationship: network_relationship,
    )
  end

  def receiver_policy_revision
    DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
      peer_forum_id: remote_forum_id,
      relationship: network_relationship,
    )
  end

  def remote_forum_id
    "dbf_11111111111111111111111111111111"
  end

  def network_relationship
    "hub_to_spoke"
  end

  def source_detail
    JSON.parse(
      File.read(
        File.expand_path("../fixtures/network-source-detail.json", __dir__),
      ),
    )
  end

  def source_policy_revision
    DiscussionBridge::DiscourseNetworkProtocol.expected_source_policy_revision(
      local_forum_id: @identity.forum_id,
      relationship: @peer.relationship,
    )
  end

  it "creates one stable local topic, renders its boundary, and replays without mutation" do
    expect(source_policy_revision).not_to eq(receiver_policy_revision)
    result = described_class.call(
      peer: @peer,
      source_detail: source_detail,
      policy_revision: source_policy_revision,
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
      policy_revision: source_policy_revision,
    )
    expect(replay.fetch("mutated")).to eq(false)
    expect(record.topic.first_post.reload.version).to eq(original_version)
    expect(DiscussionBridgeNetworkReplay.count).to eq(1)
  end

  it "rejects source work whose policy names another receiver before mutation" do
    wrong_target_policy = DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
      peer_forum_id: "dbf_#{"9" * 32}",
      relationship: network_relationship,
    )

    expect do
      described_class.call(
        peer: @peer,
        source_detail: source_detail,
        policy_revision: wrong_target_policy,
      )
    end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) do |error|
      expect(error.error_code).to eq("policy_denied")
    end
    expect(DiscussionBridgeBridgeRecord.where(direction: "to_discourse")).to be_empty
    expect(DiscussionBridgeNetworkReplay.count).to eq(0)
  end

  it "composes the opposite authorized relationship without equating receiver policy" do
    opposite_remote_id = "dbf_#{"2" * 32}"
    opposite_relationship = "spoke_to_hub"
    opposite_policy = DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
      peer_forum_id: opposite_remote_id,
      relationship: opposite_relationship,
    )
    opposite_connection, = DiscussionBridgeContentConnection.issue!(
      name: "Regional network source",
      platform: "discourse",
      allowed_origins: ["https://national.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: [],
      default_category_id: category.id,
      destination_policies: [opposite_policy],
      policy_revision: DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
        peer_forum_id: opposite_remote_id,
        relationship: opposite_relationship,
      ),
      network_enabled: true,
      network_peer_forum_id: opposite_remote_id,
      network_relationship: opposite_relationship,
    )
    opposite_peer = DiscussionBridgeNetworkPeer.create!(
      content_connection: opposite_connection,
      name: "Regional Organization",
      remote_forum_id: opposite_remote_id,
      remote_forum_name: "National Organization",
      remote_origin: "https://national.example",
      remote_connection_id: "dbc_#{"2" * 24}",
      remote_secret: "t" * 32,
      relationship: opposite_relationship,
      enabled: true,
      authorized_by: admin,
      authorized_at: Time.zone.now,
    )
    detail = source_detail
    detail["resource_id"] = SecureRandom.uuid
    detail["topic_url"] = "https://national.example/t/regional-program-update/102"
    detail["network_provenance"].merge!(
      "origin_forum_id" => opposite_remote_id,
      "origin_topic_url" => detail.fetch("topic_url"),
      "content_authority_forum_id" => opposite_remote_id,
      "relationship" => opposite_relationship,
      "operation_id" => "dbo_#{"2" * 32}",
      "route_forum_ids" => [opposite_remote_id],
    )
    incoming_revision = DiscussionBridge::DiscourseNetworkProtocol.expected_source_policy_revision(
      local_forum_id: @identity.forum_id,
      relationship: opposite_relationship,
    )

    expect(incoming_revision).not_to eq(opposite_connection.policy_revision)
    expect(
      described_class.call(
        peer: opposite_peer,
        source_detail: detail,
        policy_revision: incoming_revision,
      ),
    ).to include("outcome" => "created")
  end

  it "rejects a changed operation replay without changing the local first post" do
    described_class.call(
      peer: @peer,
      source_detail: source_detail,
      policy_revision: source_policy_revision,
    )
    record = DiscussionBridgeBridgeRecord.last
    original = record.topic.first_post.cooked
    changed = source_detail
    changed["source_revision"] = "post:501:version:3"

    expect do
      described_class.call(
        peer: @peer,
        source_detail: changed,
        policy_revision: source_policy_revision,
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
      policy_revision: source_policy_revision,
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
      policy_revision: source_policy_revision,
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
      policy_revision: source_policy_revision,
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
      policy_revision: source_policy_revision,
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

  it "uses the native Discourse character ceiling and accepts its exact complete boundary" do
    detail = source_detail
    parsed = DiscussionBridge::NetworkSourceDetail.call(payload: detail)
    receiver = described_class.new(
      peer: @peer,
      source_detail: detail,
      policy_revision: source_policy_revision,
      content_html: nil,
    )
    provenance = parsed.fetch("network_provenance")
    boundary = receiver.send(:provenance_boundary, provenance)
    read_more = provenance.fetch("origin_topic_url")
    fixed_length = receiver.send(
      :companion_raw_length,
      "<p></p>#{boundary}",
      read_more,
    )
    character_count = SiteSetting.max_post_length - fixed_length
    expect(character_count).to be_positive

    exact_body = "<p>#{"x" * character_count}</p>"
    exact_detail = parsed.merge("content_html" => exact_body)
    exact_output = receiver.send(:content_for_destination, exact_detail, provenance, @connection)
    expect(exact_output.fetch(:content_disposition)).to eq("complete")
    expect(
      receiver.send(:companion_raw_length, exact_output.fetch(:content_html), read_more),
    ).to eq(SiteSetting.max_post_length)

    overflow_body = "<p>#{"x" * (character_count + 1)}</p>"
    overflow_detail = parsed.merge("content_html" => overflow_body)
    overflow_output = receiver.send(:content_for_destination, overflow_detail, provenance, @connection)
    expect(overflow_body.bytesize + boundary.bytesize).to be < 49_152
    expect(overflow_output.fetch(:content_disposition)).to eq("excerpt")
    expect(
      receiver.send(:companion_raw_length, overflow_output.fetch(:content_html), read_more),
    ).to be <= SiteSetting.max_post_length
  end

  it "sizes complete and excerpt network content from the same final raw assembly with a generated TOC" do
    @connection.update!(generate_topic_toc: true)
    detail = source_detail
    parsed = DiscussionBridge::NetworkSourceDetail.call(payload: detail)
    receiver = described_class.new(
      peer: @peer,
      source_detail: detail,
      policy_revision: source_policy_revision,
      content_html: nil,
    )
    provenance = parsed.fetch("network_provenance")
    boundary = receiver.send(:provenance_boundary, provenance)
    read_more = provenance.fetch("origin_topic_url")
    shell = "<h2>One</h2><h2>Two</h2><p></p>#{boundary}"
    character_count = SiteSetting.max_post_length -
      receiver.send(:companion_raw_length, shell, read_more)
    expect(character_count).to be_positive

    exact_body = "<h2>One</h2><h2>Two</h2><p>#{"x" * character_count}</p>"
    exact_output = receiver.send(
      :content_for_destination,
      parsed.merge("content_html" => exact_body),
      provenance,
      @connection,
    )
    exact_raw = DiscussionBridge::TopicCreator.companion_post(
      source_url: read_more,
      content_html: exact_output.fetch(:content_html),
      source_authors: [],
      generate_topic_toc: true,
    )
    expect(exact_output.fetch(:content_disposition)).to eq("complete")
    expect(exact_raw).to include('<div data-theme-toc="true"></div>')
    expect(exact_raw.length).to eq(SiteSetting.max_post_length)

    overflow_body = "<h2>One</h2><h2>Two</h2><p>#{"x" * (character_count + 1)}</p>"
    overflow_output = receiver.send(
      :content_for_destination,
      parsed.merge("content_html" => overflow_body),
      provenance,
      @connection,
    )
    overflow_raw = DiscussionBridge::TopicCreator.companion_post(
      source_url: read_more,
      content_html: overflow_output.fetch(:content_html),
      source_authors: [],
      generate_topic_toc: true,
    )
    expect(overflow_output.fetch(:content_disposition)).to eq("excerpt")
    expect(overflow_raw.length).to be <= SiteSetting.max_post_length
    expect(overflow_raw.bytesize).to be <= destination_policy.dig("native_limit_policy", "maximum_bytes")
  end

  it "preserves the exact network source timestamp wire value" do
    detail = source_detail
    timestamp = "2026-09-27T18:00:00.123456789Z"
    detail["source_created_at"] = timestamp
    detail["source_updated_at"] = timestamp
    result = described_class.call(
      peer: @peer,
      source_detail: detail,
      policy_revision: source_policy_revision,
    )
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: result.fetch("resource_id"))
    expect(record.source_created_at_wire).to eq(timestamp)
    expect(record.source_updated_at_wire).to eq(timestamp)
  end
end
