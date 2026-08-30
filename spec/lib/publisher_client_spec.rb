# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::Publisher::Client do
  before do
    SiteSetting.discussion_bridge_publisher_receiver_url = "https://receiver.example"
    SiteSetting.discussion_bridge_publisher_connection_id = "dbc_0123456789abcdef01234567"
    ENV.stubs(:[]).with("DISCUSSION_BRIDGE_PUBLISHER_SECRET_FILE").returns("/run/discussionbridge-secret")
    File.stubs(:stat).returns(stub(file?: true, size: 32, mode: 0o100640))
    File.stubs(:binread).returns("a-secure-secret-value-that-is-long")
  end

  it "rejects a missing server-side secret-file identity" do
    ENV.stubs(:[]).with("DISCUSSION_BRIDGE_PUBLISHER_SECRET_FILE").returns("")
    expect { described_class.new }.to raise_error(described_class::Error, "missing_secret_file")
  end

  it "rejects unsafe receiver origins" do
    ["http://receiver.example", "https://user@receiver.example", "https://receiver.example/path", "https://receiver.example/?query=1", "https://receiver.example/#fragment"].each do |value|
      SiteSetting.discussion_bridge_publisher_receiver_url = value
      expect { described_class.new }.to raise_error(described_class::Error, "invalid_receiver_origin")
    end
  end

  it "rejects malformed connection and resource identities before network access" do
    SiteSetting.discussion_bridge_publisher_connection_id = "bad"
    expect { described_class.new }.to raise_error(described_class::Error, "invalid_connection_id")
    SiteSetting.discussion_bridge_publisher_connection_id = "dbc_0123456789abcdef01234567"
    expect { described_class.new.fetch("not-a-uuid") }.to raise_error(described_class::Error, "invalid_resource_id")
  end

  it "publishes the cooked first post through the unified plugin identity" do
    client = described_class.new
    topic = stub(first_post: stub(cooked: "<p>Meaningful publishing forum content.</p>"), title: "Publishing forum article")
    DiscussionBridge::Publisher::TopicIdentity.stubs(:external_id).with(topic).returns("discourse-topic:42")
    DiscussionBridge::Publisher::TopicIdentity.stubs(:canonical_url).with(topic).returns("https://publisher.example/t/article/42")
    client.expects(:request_json).with do |method, path, body:|
      record = body.fetch(:bridge_record)
      method == :post && path == "/discussion-bridge/v1/bridge-records/resolve.json" &&
        record[:content_html] == "<p>Meaningful publishing forum content.</p>" &&
        record[:adapter_id] == "discourse-discussion-bridge" &&
        record[:adapter_version] == DiscussionBridge::VERSION
    end.returns({})
    client.resolve(topic: topic, correlation_id: "correlation")
  end

  it "rejects missing or oversized source content before network access" do
    client = described_class.new
    ["", "x" * (described_class::MAX_CONTENT_HTML_BYTES + 1)].each do |content|
      topic = stub(first_post: stub(cooked: content), title: "Invalid content")
      client.expects(:request_json).never
      expect { client.resolve(topic: topic, correlation_id: "correlation") }
        .to raise_error(described_class::Error, "invalid_published_content")
    end
  end
end
