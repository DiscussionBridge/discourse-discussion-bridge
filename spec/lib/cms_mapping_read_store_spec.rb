# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsMappingReadStore do
  fab!(:admin)

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @now = Time.current
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS metadata read fixture",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @configuration = {
      "profile" => "ghost",
      "destination_origin" => "https://site.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "native:fixture",
        "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic",
        "complete_content_supported" => true,
      },
      "policy" => {
        "policy_revision" => SecureRandom.uuid,
        "enabled" => false,
        "selection" => "all_public",
        "category_ids" => [],
        "include_topic_ids" => [],
        "exclude_topic_ids" => [],
        "include_unlisted" => false,
        "publication_kind" => "dynamic",
        "presentation_mode" => "simple",
        "author_ids" => [],
        "taxonomy_ids" => [],
        "existing_record_adoption" => "disabled",
        "adoptable_resource_ids" => [],
      },
    }
    @connection.update!(cms_configuration: @configuration)
    @store =
      described_class.new(
        @connection,
        clock: -> { @now },
        authenticated_secret_digest: @connection.secret_digest,
      )
  end

  def mapping(connection: @connection, url: nil, external: nil)
    topic = Fabricate(:topic, user: admin)
    external ||= "article-#{topic.id}"
    url ||= "https://site.example/#{external}/"
    record =
      DiscussionBridgeBridgeRecord.create!(
        resource_id: SecureRandom.uuid,
        direction: "from_discourse",
        lane: "news",
        state: "healthy",
        title: topic.title,
        topic_id: topic.id,
        effective_actor_id: admin.id,
        requested_visibility: "listed",
        effective_visibility: "listed",
      )
    binding =
      DiscussionBridgeContentBinding.create!(
        bridge_record: record,
        content_connection: connection,
        role: "presentation",
        state: "active",
        external_id: external,
        canonical_url: url,
        identity_digest: Digest::SHA256.hexdigest("#{connection.public_id}\n#{external}"),
        canonical_url_digest: Digest::SHA256.hexdigest("#{connection.public_id}\n#{url}"),
        native_materialization: true,
        presentation_mode: "simple",
        cms_protocol_version: 2,
      )
    DiscussionBridgeCmsMapping.create!(
      mapping_id: SecureRandom.uuid,
      content_connection: connection,
      content_binding: binding,
      source_id: "topic:#{topic.id}",
      mapping_revision: SecureRandom.uuid,
    )
  end

  def rejected(code, &block)
    expect(&block).to raise_error(DiscussionBridge::CmsProtocol::Error) do |error|
      expect(error.code).to eq(code)
    end
  end

  def history(entry_mapping, index, url: nil)
    DiscussionBridgeCmsUrlHistoryEntry.create!(
      cms_mapping_id: entry_mapping.id,
      url: url || "https://site.example/prior-#{index}/",
      retired_at: @now + index,
      move_id: SecureRandom.uuid,
      created_at: @now + index,
    )
  end

  it "reads an empty off-policy inventory without discovering sources or work" do
    expect(@store.inventory.body).to eq("items" => [], "next_cursor" => nil)
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "keeps a fixed 100-item snapshot and exact replay across later mapping changes" do
    mappings = 101.times.map { mapping }
    first = @store.inventory.body
    expect(first.fetch("items").size).to eq(100)
    expect(JSON.generate(first).bytesize).to be <= 262_144
    token = first.fetch("next_cursor")
    last_original = mappings.last.mapping_id
    mappings.last.update!(mapping_state: "attention")
    mapping
    second = @store.inventory("cursor" => token).body
    expect(second.fetch("items").map { |item| item.fetch("mapping_id") }).to eq([last_original])
    expect(second.dig("items", 0, "mapping_state")).to eq("pending")
    expect(second.fetch("next_cursor")).to be_nil
    expect(@store.inventory("cursor" => token).body).to eq(second)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(JSON.generate(first)).not_to include(@secret, "lease_token", "content_html")
  end

  it "snapshots append-only URL ancestry including repeated retirement of the same URL" do
    owned = mapping
    101.times { |index| history(owned, index, url: "https://site.example/reused/") }
    first = @store.url_history(owned.mapping_id).body
    expect(first.fetch("items").size).to eq(100)
    history(owned, 102)
    token = first.fetch("next_cursor")
    last = @store.url_history(owned.mapping_id, "cursor" => token).body
    expect(last.fetch("items").size).to eq(1)
    expect(last.dig("items", 0, "url")).to eq("https://site.example/reused/")
    expect(last.fetch("next_cursor")).to be_nil
    expect(@store.url_history(owned.mapping_id, "cursor" => token).body).to eq(last)
    expect(DiscussionBridge::CmsMappingProjection.call(owned).fetch("retired_url_count")).to eq(102)
  end

  it "reduces page size to fit actual encoded metadata without losing an entry" do
    # Valid opaque strings need JSON escaping; each URL and identity still
    # remains within its own approved field bound.
    100.times do |index|
      wide =
        mapping(
          url: "https://site.example/#{index}/#{"a" * 1980}",
          external: "#{index}#{'"' * 250}",
        )
      wide.update!(
        mapping_revision: '"' * 128,
        desired_source_revision: '"' * 128,
        destination_native_id: "#{index}#{'"' * (255 - index.to_s.bytesize)}",
        destination_native_revision: '"' * 128,
      )
    end
    seen = []
    query = {}
    loop do
      page = @store.inventory(query).body
      expect(JSON.generate(page).bytesize).to be <= 262_144
      seen.concat(page.fetch("items").map { |item| item.fetch("mapping_id") })
      break unless page.fetch("next_cursor")
      expect(page.fetch("items").size).to be < 100
      query = { "cursor" => page.fetch("next_cursor") }
    end
    expect(seen.size).to eq(100)
    expect(seen.uniq.size).to eq(100)
  end

  it "binds continuation to owner, route, mapping, policy and expiry" do
    owned = mapping
    101.times { |index| history(owned, index) }
    token = @store.url_history(owned.mapping_id).body.fetch("next_cursor")
    rejected("cursor_scope_changed") { @store.inventory("cursor" => token) }
    other_owned = mapping
    rejected("cursor_scope_changed") do
      @store.url_history(other_owned.mapping_id, "cursor" => token)
    end
    rejected("cursor_invalid") { @store.inventory("cursor" => "unknown") }
    @now += 86_400
    rejected("cursor_expired") { @store.url_history(owned.mapping_id, "cursor" => token) }
  end

  it "rejects a scope change, disabled connection and rotated authentication" do
    owned = mapping
    101.times { |index| history(owned, index) }
    token = @store.url_history(owned.mapping_id).body.fetch("next_cursor")
    changed = @configuration.deep_dup
    changed["policy"]["policy_revision"] = SecureRandom.uuid
    @connection.update!(cms_configuration: changed)
    rejected("cursor_scope_changed") { @store.url_history(owned.mapping_id, "cursor" => token) }
    @connection.update!(enabled: false)
    rejected("connection_disabled") { @store.inventory }
    @connection.update!(enabled: true)
    @connection.rotate_secret!
    rejected("authentication_failed") { @store.inventory }
  end

  it "reports missing snapshot items instead of skipping or rewinding" do
    owned = mapping
    102.times { |index| history(owned, index) }
    token = @store.url_history(owned.mapping_id).body.fetch("next_cursor")
    cursor = DiscussionBridgeCmsReadCursor.find_by!(token_digest: Digest::SHA256.hexdigest(token))
    cursor.cms_read_snapshot.items.find_by!(ordinal: 100).destroy!
    rejected("cursor_expired") { @store.url_history(owned.mapping_id, "cursor" => token) }
  end

  it "does not disclose another connection's mapping even with its UUID" do
    other, =
      DiscussionBridgeContentConnection.issue!(
        name: "Other CMS owner",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    foreign = mapping(connection: other)
    rejected("resource_not_found") { @store.url_history(foreign.mapping_id) }
    expect(@store.inventory.body.fetch("items")).to eq([])
  end

  it "fails explicit out-of-scope owned mappings instead of silently omitting them" do
    owned = mapping
    owned.content_binding.update!(canonical_url: "https://outside.example/article/")
    rejected("scope_denied") { @store.inventory }
    rejected("scope_denied") { @store.url_history(owned.mapping_id) }
    expect(DiscussionBridgeCmsReadSnapshot.count).to eq(0)
  end
end
