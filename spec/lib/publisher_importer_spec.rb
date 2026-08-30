# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::Publisher::Importer do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_publisher_receiver_url = "https://receiver.example"
    SiteSetting.discussion_bridge_publisher_import_category_id = category.id
    @resource_id = "123e4567-e89b-42d3-a456-426614174000"
    @record = { "bridge_record" => { "resource_id" => @resource_id, "direction" => "from_discourse", "state" => "healthy", "title" => "Imported roadmap", "topic_id" => 42, "topic_url" => "https://receiver.example/t/roadmap/42", "content_html" => "<p>Safe <strong>roadmap</strong> content.</p>" } }
    client = mock
    client.stubs(:fetch).with(@resource_id).returns(@record)
    DiscussionBridge::Publisher::Client.stubs(:new).returns(client)
  end

  it "creates one local presentation topic and resolves an exact retry" do
    first = described_class.new(user: admin, resource_id: @resource_id).call
    second = described_class.new(user: admin, resource_id: @resource_id).call
    expect(second.id).to eq(first.id)
    expect(first.custom_fields[DiscussionBridge::Publisher::SOURCE_RESOURCE_ID_FIELD]).to eq(@resource_id)
    expect(first.custom_fields[DiscussionBridge::Publisher::PUBLISH_STATE_FIELD]).to eq("imported")
    expect(first.first_post.raw).to include("Safe roadmap content")
  end

  it "rejects the wrong direction before creating a topic" do
    @record["bridge_record"]["direction"] = "to_discourse"
    expect { described_class.new(user: admin, resource_id: @resource_id).call }.to raise_error(described_class::Error, "invalid_direction")
  end
end
