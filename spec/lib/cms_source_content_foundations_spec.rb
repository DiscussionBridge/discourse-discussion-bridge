# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridge::CmsSourceStore do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "Native source content fixture", platform: "ghost",
      allowed_origins: ["https://site.example"], allowed_directions: ["from_discourse"], allowed_lanes: ["news"],
    )
    @connection.update!(cms_configuration: {
      "profile" => "ghost", "destination_origin" => "https://site.example", "publication_lane" => "news",
      "native_capabilities" => { "native_revision" => "native:content-fixture", "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic", "complete_content_supported" => true },
      "policy" => { "policy_revision" => SecureRandom.uuid, "enabled" => true, "selection" => "all_public",
        "category_ids" => [], "include_topic_ids" => [], "exclude_topic_ids" => [], "include_unlisted" => false,
        "publication_kind" => "dynamic", "presentation_mode" => "simple", "author_ids" => [], "taxonomy_ids" => [] },
    })
    @store = described_class.new(@connection)
  end

  def stored_revision(intent)
    intent.source_revisions.find_by!(source_revision: intent.current_source_revision)
  end

  it "retains exact media-only cooked source, native original and edition-captured base" do
    # Fixture represents already cooked native output, not player qualification.
    cooked = '<video poster="../poster.png"><source src="./film.mp4"><track src="/captions.vtt"></video>'
    raw = "Native original video source"
    first_post.update_columns(raw: raw, cooked: cooked)
    intent = @store.refresh_topic!(topic.id)
    stored = stored_revision(intent)
    metadata = stored.source_metadata.deep_dup
    expect(intent.state).to eq("active")
    expect(stored.content_bytes_blob.b).to eq(cooked.b)
    expect(metadata.fetch("content_bytes")).to eq(cooked.bytesize)
    expect(metadata.fetch("content_sha256")).to eq(Digest::SHA256.hexdigest(cooked.b))
    expect(metadata.fetch("topic_url")).to eq(topic.url)
    expect(first_post.reload.raw).to eq(raw)
    expect(first_post.cooked).to eq(cooked)
    topic.update_column(:slug, "later-current-location")
    expect(stored.reload.source_metadata).to eq(metadata)
    expect(stored.content_bytes_blob.b).to eq(cooked.b)
    expect(stored.source_metadata.fetch("topic_url")).not_to eq(topic.reload.url)
  end

  it "does not require HTML formatting or stripped prose for native source admission" do
    first_post.update_columns(raw: "Native plain source", cooked: "Unformatted native text")
    intent = @store.refresh_topic!(topic.id)
    expect(intent.state).to eq("active")
    expect(stored_revision(intent).content_bytes_blob.b).to eq("Unformatted native text".b)
  end

  [nil, ""].each do |unavailable|
    it "retains accepted source and reports unavailable cooked #{unavailable.inspect} as Bridge attention" do
      intent = @store.refresh_topic!(topic.id)
      accepted = stored_revision(intent).attributes.deep_dup
      events = intent.cms_source_stream.source_events.order(:id).map(&:attributes)
      # Current Core's cooked column is NOT NULL. Keep the native row valid;
      # the nil case injects unavailable extraction evidence at the exact SQL
      # projection boundary instead of fabricating an impossible persisted row.
      first_post.update_columns(raw: "Existing nontext native source", cooked: unavailable || "")
      if unavailable.nil?
        source_post_id = first_post.id
        columns = DiscussionBridge::SourceEdition::SOURCE_COLUMNS + ["users.id"]
        allow_any_instance_of(ActiveRecord::Relation).to receive(:pluck).and_wrap_original do |original, *selected|
          rows = original.call(*selected)
          if selected == columns
            rows = rows.map do |row|
              row = row.dup
              row[10] = nil if row[4] == source_post_id
              row
            end
          end
          rows
        end
      end
      refreshed = @store.refresh_topic!(topic.id)
      expect(refreshed.state).to eq("attention")
      expect(refreshed.attention_code).to eq("metadata_unavailable")
      expect(stored_revision(refreshed).attributes).to eq(accepted)
      expect(refreshed.cms_source_stream.source_events.order(:id).map(&:attributes)).to eq(events)
      expect(first_post.reload.raw).to eq("Existing nontext native source")
    end
  end

  it "checks complete snapshot evidence before parsing a native source preview" do
    inspector = DiscussionBridge::CmsAdminInspectionStore.new(@connection, actor: admin, guardian: admin.guardian)
    snapshot = DiscussionBridgeContentConnection.transaction do
      @store.send(:capture_snapshot_locked, topic, @connection.cms_configuration.fetch("policy"))
    end
    corrupted = described_class::Snapshot.new(metadata: snapshot.metadata, body: snapshot.body + "corrupted")
    allow_any_instance_of(described_class).to receive(:capture_snapshot_locked).and_return(corrupted)
    allow(Nokogiri::HTML5).to receive(:fragment).and_call_original
    expect { inspector.preview(topic.id.to_s) }.to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq("content_hash_mismatch")
    }
    expect(Nokogiri::HTML5).not_to have_received(:fragment)
  end
end
