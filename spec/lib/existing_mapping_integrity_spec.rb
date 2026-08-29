# frozen_string_literal: true

describe DiscussionBridge::ExistingMappingIntegrity do
  fab!(:author, :user)

  it "keeps an administrator-selected listed From Discourse topic usable" do
    topic = Fabricate(:topic, user: author, visible: true)
    Fabricate(:post, topic: topic, user: author, post_number: 1)
    connection, = DiscussionBridgeContentConnection.issue!(
      name: "Publishing WordPress",
      platform: "wordpress",
      allowed_origins: ["https://publisher.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    )
    record = DiscussionBridgeBridgeRecord.create!(
      resource_id: SecureRandom.uuid,
      direction: "from_discourse",
      state: "healthy",
      title: topic.title,
      topic_id: topic.id,
      effective_actor_id: author.id,
      requested_visibility: "listed",
      effective_visibility: "listed",
    )
    DiscussionBridgeContentBinding.create!(
      bridge_record: record,
      content_connection: connection,
      role: "presentation",
      state: "active",
      external_id: "featured-topic",
      canonical_url: "https://publisher.example/community/featured-topic/",
      identity_digest: Digest::SHA256.hexdigest("#{connection.public_id}\nfeatured-topic"),
      canonical_url_digest: Digest::SHA256.hexdigest(
        "#{connection.public_id}\nhttps://publisher.example/community/featured-topic/",
      ),
      activated_at: Time.zone.now,
    )

    result = described_class.current(
      mapping_id: record.id,
      expected_topic_id: topic.id,
      expected_updated_at: record.updated_at,
      record_type: "bridge_record",
    )

    expect(result.usable?).to eq(true)
    expect(result.mapping).to eq(record)
  end
end
