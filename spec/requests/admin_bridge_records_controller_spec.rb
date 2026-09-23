# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::AdminBridgeRecordsController do
  fab!(:admin)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "Publishing platform",
      platform: "astro",
      allowed_origins: ["https://publisher.example.com"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    )
    @connection.update!(forum_publication_enabled: true)
  end

  def create_publication(title:, slug:, work_state:, action: "publish", destination_state: "pending")
    topic = Fabricate(:topic, user: admin, title: title)
    Fabricate(:post, topic: topic, user: admin, post_number: 1)
    result = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: @connection.id,
      topic_id: topic.id,
      external_id: slug,
      canonical_url: "https://publisher.example.com/#{slug}/",
      native_materialization: true,
    )
    result.record.update!(title: title, destination_state: destination_state)
    DiscussionBridgePublicationWorkItem.create!(
      content_connection: @connection,
      bridge_record: result.record,
      topic_id: topic.id,
      action: action,
      state: work_state,
    )
    result.record
  end

  it "returns explicit publication state and sorts the complete result set server-side" do
    create_publication(
      title: "Zoning policy overview",
      slug: "zulu",
      work_state: "current",
      destination_state: "healthy",
    )
    create_publication(
      title: "Agriculture policy digest",
      slug: "alpha",
      work_state: "unpublished",
      action: "unpublish",
      destination_state: "held",
    )
    create_publication(
      title: "Medical coverage update",
      slug: "middle",
      work_state: "queued",
    )

    sign_in(admin)
    get "/discussion-bridge/admin/bridge-records.json", params: { sort: "publication", order: "asc" }

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("sorting")).to eq("sort" => "publication", "order" => "asc")
    expect(response.parsed_body.fetch("bridge_records").map { |record| record.fetch("publication_state") })
      .to eq(%w[not_published pending_publication published])

    get "/discussion-bridge/admin/bridge-records.json", params: { sort: "title", order: "asc" }
    expect(response.parsed_body.fetch("bridge_records").map { |record| record.fetch("title") })
      .to eq(["Agriculture policy digest", "Medical coverage update", "Zoning policy overview"])
  end

  it "rejects unrecognized sort columns and directions" do
    sign_in(admin)

    get "/discussion-bridge/admin/bridge-records.json", params: { sort: "resource_id; DROP TABLE topics" }
    expect(response).to have_http_status(:bad_request)

    get "/discussion-bridge/admin/bridge-records.json", params: { order: "sideways" }
    expect(response).to have_http_status(:bad_request)
  end
end
