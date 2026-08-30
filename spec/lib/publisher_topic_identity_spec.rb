# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::Publisher::TopicIdentity do
  fab!(:topic)

  it "binds the stable topic id to the exact publishing origin" do
    expect(described_class.external_id(topic)).to match(/\Adiscourse-topic:[0-9a-f]{64}:#{topic.id}\z/)
    expect(described_class.canonical_url(topic)).to eq("#{Discourse.base_url}#{topic.relative_url}")
  end
end
