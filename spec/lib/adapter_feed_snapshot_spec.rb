# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::AdapterFeedSnapshot do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    @connection, =
      DiscussionBridgeContentConnection.issue!(
        name: "Native snapshot consumer",
        platform: "astro",
        allowed_origins: ["https://astro.example.com"],
        allowed_directions: ["from_discourse"],
      )
    @record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: topic.id,
        external_id: "snapshot-source",
        canonical_url: "https://astro.example.com/snapshot-source/",
      ).record
    @records =
      DiscussionBridgeBridgeRecord.joins(:content_bindings).where(
        discussion_bridge_content_bindings: {
          content_connection_id: @connection.id,
          state: "active",
        },
      )
  end

  it "invalidates an existing feed token after a grace-period edit without replacing record or binding" do
    first_post.update!(last_editor_id: admin.id, last_version_at: Time.zone.now)
    original = described_class.capture(@records)
    token = described_class.issue(connection: @connection, snapshot: original)
    record_updated_at = @record.updated_at
    binding_updated_at = @record.active_binding("presentation").updated_at
    version = first_post.version

    expect(
      first_post.revise(admin, { raw: "A native edit inside the revision grace period." }),
    ).to eq(true)
    expect(first_post.reload.version).to eq(version)
    updated = described_class.capture(@records)
    expect(updated.total).to eq(original.total)
    expect(updated.digest).not_to eq(original.digest)
    expect(described_class.valid?(token, connection: @connection, snapshot: updated)).to eq(false)
    expect(@record.reload.updated_at).to eq_time(record_updated_at)
    expect(@record.active_binding("presentation").updated_at).to eq_time(binding_updated_at)
    next_token = described_class.issue(connection: @connection, snapshot: updated)
    expect(described_class.valid?(next_token, connection: @connection, snapshot: updated)).to eq(
      true,
    )
  end

  it "invalidates source snapshots when the effective publication forum name changes" do
    original = described_class.capture(@records)
    SiteSetting.discussion_bridge_forum_name = "Different effective forum display name"
    expect(described_class.capture(@records).digest).not_to eq(original.digest)
  end

  it "hashes the unchanged complete inventory across bounded census batches" do
    2.times do |index|
      source = Fabricate(:topic, user: admin)
      Fabricate(:post, topic: source, user: admin, post_number: 1)
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: source.id,
        external_id: "snapshot-source-#{index}",
        canonical_url: "https://astro.example.com/snapshot-source-#{index}/",
      )
    end
    rows =
      @records.reorder("discussion_bridge_bridge_records.id ASC").pluck(
        "discussion_bridge_bridge_records.id",
        "discussion_bridge_bridge_records.updated_at",
        "discussion_bridge_content_bindings.id",
        "discussion_bridge_content_bindings.updated_at",
        "discussion_bridge_bridge_records.direction",
        "discussion_bridge_bridge_records.topic_id",
        "discussion_bridge_bridge_records.resource_id",
      )
    editions = DiscussionBridge::SourceEdition.editions(rows.map { |row| row[5] })
    canonical =
      rows
        .map do |row|
          (row + [editions.fetch(row[5])])
            .map { |value| value.respond_to?(:utc) ? value.utc.iso8601(6) : value.to_s }
            .join(":")
        end
        .join("\n")
    stub_const(described_class, :BATCH_SIZE, 2) do
      allow(DiscussionBridge::SourceEdition).to receive(:editions).and_wrap_original do |method, ids|
        expect(ids.length).to be <= 2
        method.call(ids)
      end

      result = described_class.capture(@records.includes(topic: :first_post))
      expect(result.total).to eq(3)
      expect(result.digest).to eq(Digest::SHA256.hexdigest(canonical))
      expect(DiscussionBridge::SourceEdition).to have_received(:editions).twice
    end
  end
end
