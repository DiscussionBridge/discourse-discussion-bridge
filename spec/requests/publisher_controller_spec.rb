# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::PublisherController do
  fab!(:admin)
  fab!(:user)
  fab!(:topic)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
  end

  it "requires a staff session" do
    sign_in(user)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json"
    expect(response).to have_http_status(:forbidden)
  end

  it "queues an explicitly selected visible topic for a staff user" do
    sign_in(admin)
    Jobs.expects(:enqueue).with(:discussion_bridge_publisher_deliver, topic_id: topic.id)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("queued" => true, "topic_id" => topic.id)
  end

  it "exposes no publishing route while publishing is disabled" do
    SiteSetting.discussion_bridge_publisher_enabled = false
    sign_in(admin)
    get "/discussion-bridge/v1/publisher/topics/#{topic.id}/status.json"
    expect(response).to have_http_status(:not_found)
  end

  it "returns a secret-free native publishing overview" do
    SiteSetting.discussion_bridge_publisher_receiver_url = "https://receiver.example.com"
    SiteSetting.discussion_bridge_publisher_connection_id = "dbc_0123456789abcdef01234567"
    SiteSetting.discussion_bridge_publisher_lane = "publisher-demo"
    sign_in(admin)
    DiscussionBridge::Publisher::Client.expects(:new).raises(DiscussionBridge::Publisher::Client::Error, "unreadable_secret_file")
    get "/discussion-bridge/admin/publishing.json"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("product", "blockers")).to eq(["secret_file"])
    expect(response.parsed_body.dig("connection", "connection_id")).to eq("dbc_0123456789abcdef01234567")
    expect(response.body).not_to include("X-DiscussionBridge-Secret")
  end
end
