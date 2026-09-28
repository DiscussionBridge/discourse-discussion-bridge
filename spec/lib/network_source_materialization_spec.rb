# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::SourceRevisionMaterializer do
  fab!(:admin)
  fab!(:category)

  before do
    @original_forum_name = ENV["DISCUSSIONBRIDGE_FORUM_NAME"]
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "National Organization"
    DiscussionBridgeForumIdentity.enable!(actor: admin)
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "Regional chapter destination",
      platform: "discourse",
      allowed_origins: [DiscussionBridge::CanonicalSource.origin(Discourse.base_url)],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
      destination_policies: [destination_policy],
      policy_revision: "policy:2026-09-27:1",
      network_enabled: true,
      network_peer_forum_id: "dbf_22222222222222222222222222222222",
      network_relationship: "hub_to_spoke",
    )
    @topic = Fabricate(:topic, user: admin, category: category, title: "National update", visible: true)
    @post = Fabricate(:post, topic: @topic, user: admin, post_number: 1, raw: "National update")
    @post.update_columns(cooked: "<p>National update.</p>")
    @record = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: @connection.id,
      topic_id: @topic.id,
      external_id: "national-update",
      canonical_url: "#{Discourse.base_url}/published/national-update",
      native_materialization: true,
    ).record
  end

  after { ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = @original_forum_name }

  def destination_policy
    {
      "destination_policy_id" => "destination:discourse:network:1",
      "profile" => "discourse_as_publisher",
      "presentation_mode" => "interactive",
      "container_mapping" => {
        "source" => "discourse:category:national",
        "destination" => "discourse:category:regional",
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

  it "creates stable per-revision provenance only after explicit network enablement" do
    first = DiscussionBridge::SourceRevisionMaterializer.call(
      record: @record,
      connection: @connection,
    ).revision
    replay = DiscussionBridge::SourceRevisionMaterializer.call(
      record: @record,
      connection: @connection,
    ).revision

    expect(replay.id).to eq(first.id)
    expect(first.network_provenance).to include(
      "origin_forum_id" => DiscussionBridgeForumIdentity.current.forum_id,
      "origin_forum_name" => "National Organization",
      "relationship" => "hub_to_spoke",
      "route_forum_ids" => [DiscussionBridgeForumIdentity.current.forum_id],
      "managed_scope" => "first_post",
    )
    expect(first.network_provenance.fetch("operation_id")).to match(
      DiscussionBridge::DiscourseNetworkProtocol::OPERATION_ID_PATTERN,
    )
    work = @connection.publication_works.find_by!(
      source_revision: first.source_revision,
      destination_policy_id: destination_policy.fetch("destination_policy_id"),
    )
    expect(work).to have_attributes(
      action: "publish",
      state: "available",
      resolved_container: {
        "id" => "discourse:category:regional",
        "kind" => "discourse_category",
      },
    )

    @post.update_columns(cooked: "<p>Revised national update.</p>", updated_at: 1.minute.from_now)
    revised = DiscussionBridge::SourceRevisionMaterializer.call(
      record: @record,
      connection: @connection,
    ).revision
    expect(revised.id).not_to eq(first.id)
    expect(revised.network_provenance.fetch("operation_id")).not_to eq(
      first.network_provenance.fetch("operation_id"),
    )
  end

  it "issues a new operation when approved destination policy changes" do
    first = DiscussionBridge::SourceRevisionMaterializer.call(
      record: @record,
      connection: @connection,
    ).revision
    @connection.update!(policy_revision: "policy:2026-09-28:2")

    revised = DiscussionBridge::SourceRevisionMaterializer.call(
      record: @record,
      connection: @connection,
    ).revision

    expect(revised.id).not_to eq(first.id)
    expect(revised.network_provenance.fetch("operation_id")).not_to eq(
      first.network_provenance.fetch("operation_id"),
    )
    expect(@connection.publication_works.find_by!(source_revision: revised.source_revision)).to have_attributes(
      policy_revision: "policy:2026-09-28:2",
      state: "available",
    )
  end

  it "does not automatically relay a network-received topic" do
    DiscussionBridgeBridgeRecord.create!(
      resource_id: SecureRandom.uuid,
      direction: "to_discourse",
      state: "healthy",
      title: @topic.title,
      topic_id: @topic.id,
      network_provenance: {
        "origin_forum_id" => "dbf_33333333333333333333333333333333",
      },
    )

    expect(
      DiscussionBridge::SourceRevisionMaterializer.unavailability_reason(
        record: @record,
        connection: @connection,
      ),
    ).to eq("policy_removed")
  end
end
