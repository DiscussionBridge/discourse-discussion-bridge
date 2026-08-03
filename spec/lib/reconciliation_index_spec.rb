# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::ReconciliationIndex do
  fab!(:actor, :admin)
  fab!(:category)
  fab!(:other_category, :category)
  fab!(:tag) { Fabricate(:tag, name: "bridge-docs") }

  before do
    SiteSetting.discussion_bridge_service_username = actor.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = tag.name
    SiteSetting.discussion_bridge_lane_policies = "[]"
  end

  def create_mapping(state: "complete", topic: nil, lane: "docs", updated_at: Time.zone.now)
    DiscussionBridgeConnection.create!(
      connection_id: "astro-alpha",
      canonical_source_url: "https://example.com/#{SecureRandom.hex(4)}",
      source_identity_digest: SecureRandom.hex(32),
      state: state,
      reservation_token: state == "reserved" ? SecureRandom.hex(32) : nil,
      topic_id: topic&.id,
      effective_actor_id: actor.id,
      lane: lane,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
      created_at: updated_at,
      updated_at: updated_at,
    )
  end

  def compliant_topic
    topic = Fabricate(:topic, user: actor, category: category, visible: false)
    topic.tags = [tag]
    topic
  end

  it "returns no issue for a complete mapping matching current forum policy" do
    create_mapping(topic: compliant_topic)

    result = described_class.call

    expect(result[:items]).to eq([])
    expect(result[:summary]).to eq(critical: 0, high: 0, medium: 0, total: 0)
  end

  it "detects missing topics and stale or failed mappings" do
    create_mapping(topic: nil)
    create_mapping(state: "failed")
    create_mapping(state: "reserved", updated_at: 20.minutes.ago)

    result = described_class.call

    expect(result[:items].pluck(:code)).to contain_exactly("topic_missing", "failed_mapping", "stale_reservation")
  end

  it "detects forum policy drift without mutating the mapping or topic" do
    topic = Fabricate(:topic, user: actor, category: other_category, visible: true)
    mapping = create_mapping(topic: topic)

    result = described_class.call(query: mapping.source_identity_digest, severity: "medium")

    expect(result[:items].pluck(:code)).to contain_exactly("category_drift", "tag_drift", "visibility_drift")
    expect(mapping.reload).to have_attributes(topic_id: topic.id, state: "complete")
    expect(topic.reload).to have_attributes(category_id: other_category.id, visible: true)
  end

  it "detects an unknown configured lane as a high-severity issue" do
    SiteSetting.discussion_bridge_lane_policies = [
      { lane: "news", category_id: category.id, tags: [tag.name], visibility: "unlisted" },
    ].to_json
    mapping = create_mapping(topic: compliant_topic, lane: "docs")

    result = described_class.call(query: mapping.canonical_source_url)

    expect(result[:items]).to contain_exactly(include(code: "lane_denied", severity: "high", recommendation: "review_lane_policy"))
  end
end
