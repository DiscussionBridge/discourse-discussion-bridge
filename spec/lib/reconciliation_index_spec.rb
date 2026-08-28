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
    Fabricate(:post, topic: topic, user: actor, post_number: 1) unless topic.first_post
    topic.tags = [tag]
    topic
  end

  it "returns no issue for a complete mapping matching current forum policy" do
    create_mapping(topic: compliant_topic)

    result = described_class.call

    expect(result[:items]).to eq([])
    expect(result[:summary]).to eq(critical: 0, high: 0, medium: 0, total: 0)
  end

  it "covers every shared estate integrity reason with a reconciliation code" do
    expect(described_class::RECOMMENDATIONS.keys).to include(
      *DiscussionBridge::ExistingMappingIntegrity::ESTATE_REASON_TO_RECONCILIATION_CODE.values,
    )
    expect(DiscussionBridge::ExistingMappingIntegrity::REQUEST_RELATIVE_REASONS).to eq(
      ["mapping_lane_drift"],
    )
  end

  it "detects missing topics and stale or failed mappings" do
    create_mapping(topic: nil)
    create_mapping(state: "failed")
    create_mapping(state: "reserved", updated_at: 20.minutes.ago)

    result = described_class.call

    expect(result[:items].pluck(:code)).to contain_exactly("topic_missing", "failed_mapping", "stale_reservation")
  end

  it "detects file-index aliases that identify one canonical route" do
    first = create_mapping(topic: compliant_topic)
    first.update!(canonical_source_url: "https://example.com/comments/page/index/")
    second = create_mapping(topic: compliant_topic)
    second.update!(canonical_source_url: "https://example.com/comments/page/")

    result = described_class.call

    expect(result[:items].select { |item| item[:code] == "duplicate_canonical_route" }.pluck(:mapping_id)).to contain_exactly(first.id, second.id)
  end

  it "detects deleted topics and missing or deleted companion first posts" do
    deleted_topic = compliant_topic
    deleted_topic.update_column(:deleted_at, Time.zone.now)
    create_mapping(topic: deleted_topic)

    deleted_post_topic = compliant_topic
    deleted_post = deleted_post_topic.reload.first_post
    create_mapping(topic: deleted_post_topic)
    deleted_post.update_column(:deleted_at, Time.zone.now)

    missing_post_topic = Fabricate(:topic, user: actor, category: category, visible: false)
    missing_post_topic.tags = [tag]
    create_mapping(topic: missing_post_topic)

    result = described_class.call

    expect(result[:items].pluck(:code)).to include(
      "topic_deleted",
      "first_post_deleted",
      "first_post_missing",
    )
  end

  it "detects forum policy drift without mutating the mapping or topic" do
    topic = Fabricate(:topic, user: actor, category: other_category, visible: true)
    mapping = create_mapping(topic: topic)

    result = described_class.call(query: mapping.source_identity_digest, severity: "medium")

    expect(result[:items].pluck(:code)).to contain_exactly("category_drift", "tag_drift", "visibility_drift")
    expect(mapping.reload).to have_attributes(topic_id: topic.id, state: "complete")
    expect(topic.reload).to have_attributes(category_id: other_category.id, visible: true)
  end

  it "projects every estate-detectable topic and visibility integrity blocker" do
    closed = compliant_topic
    closed.update!(closed: true)
    create_mapping(topic: closed)

    archived = compliant_topic
    archived.update!(archived: true)
    create_mapping(topic: archived)

    nonregular = compliant_topic
    nonregular.update_columns(archetype: Archetype.private_message, category_id: nil)
    create_mapping(topic: nonregular)

    visibility_mapping = create_mapping(topic: compliant_topic)
    visibility_mapping.update!(effective_visibility: "listed")

    result = described_class.call

    expect(result[:items].pluck(:code)).to include(
      "topic_closed",
      "topic_archived",
      "topic_archetype_mismatch",
      "effective_visibility_drift",
    )
    expect(result[:items]).to all(include(:recommendation))
  end

  it "reports invalid lane policy configuration for mapped estate rows" do
    create_mapping(topic: compliant_topic)
    SiteSetting.stubs(:discussion_bridge_lane_policies).returns("{")

    result = described_class.call

    expect(result[:items]).to contain_exactly(
      include(code: "lane_policy_invalid", severity: "high", recommendation: "review_lane_policy"),
    )
  end

  it "detects an unknown configured lane as a high-severity issue" do
    SiteSetting.discussion_bridge_lane_policies = [
      { lane: "news", category_id: category.id, tags: [tag.name], visibility: "unlisted" },
    ].to_json
    mapping = create_mapping(topic: compliant_topic, lane: "docs")

    result = described_class.call(query: mapping.canonical_source_url)

    expect(result[:items]).to contain_exactly(include(code: "lane_denied", severity: "high", recommendation: "review_lane_policy"))
  end

  it "keeps estate-wide counts and stable pagination beyond one page" do
    30.times { create_mapping(state: "failed") }

    first = described_class.call(severity: "medium", page: 1)
    second = described_class.call(severity: "medium", page: 2)

    expect(first.dig(:pagination, :total)).to eq(30)
    expect(first[:items].length).to eq(25)
    expect(second[:items].length).to eq(5)
    expect(first[:items].pluck(:mapping_id) & second[:items].pluck(:mapping_id)).to be_empty
    expect(first[:summary]).to eq(critical: 0, high: 0, medium: 30, total: 30)
  end

  it "rejects unbounded query and page inputs" do
    expect { described_class.call(query: "x" * 201) }.to raise_error(ArgumentError)
    expect { described_class.call(page: described_class::MAX_PAGE + 1) }.to raise_error(ArgumentError)
  end

  it "escapes wildcard and backslash query input without changing the result set" do
    create_mapping(state: "failed")

    expect(described_class.call(query: "%_\\")[:items]).to eq([])
  end
end
