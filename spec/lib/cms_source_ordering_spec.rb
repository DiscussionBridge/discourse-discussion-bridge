# frozen_string_literal: true

require "rails_helper"

# Native Rails/PostgreSQL regressions. The standalone companion in spec/scripts
# covers the actual producer methods with model doubles; it is not this gate.
RSpec.describe DiscussionBridge::CmsSourceStore do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    SiteSetting.login_required = false
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "Source ordering regression", platform: "ghost",
      allowed_origins: ["https://site.example"], allowed_directions: ["from_discourse"], allowed_lanes: ["news"],
    )
    @config = {
      "profile" => "ghost", "destination_origin" => "https://site.example", "publication_lane" => "news",
      "native_capabilities" => { "native_revision" => "ordering:1", "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic", "complete_content_supported" => true },
      "policy" => { "policy_revision" => SecureRandom.uuid, "enabled" => true, "selection" => "all_public",
        "category_ids" => [], "include_topic_ids" => [], "exclude_topic_ids" => [], "include_unlisted" => false,
        "publication_kind" => "dynamic", "presentation_mode" => "simple", "author_ids" => [], "taxonomy_ids" => [] },
    }
    @connection.update!(cms_configuration: @config)
    @store = described_class.new(@connection)
    @stream = DiscussionBridgeCmsSourceStream.create!(
      content_connection: @connection, publication_lane: "news", scan_state: "complete", scan_phase: "retirement",
      scan_scope_signature: @store.scope_fingerprint(@config),
    )
    @intent = @stream.source_intents.create!(topic_id: topic.id, source_id: "source:one", state: "revoked")
  end

  def revocation
    { "event_type" => "revocation", "source_id" => @intent.source_id,
      "last_source_revision" => nil, "reason" => "source_ineligible" }
  end

  def allocate
    @store.send(:transaction) do |config|
      stream = @store.send(:stream!, config)
      @store.send(:event!, stream, @intent, revocation)
    end
  end

  def insert_event(sequence, fields = revocation, intent = @intent)
    payload = fields.merge("event_id" => SecureRandom.uuid, "event_sequence" => sequence.to_s)
    @stream.source_events.create!(cms_source_intent: intent, event_id: payload.fetch("event_id"),
      event_sequence: sequence, payload: payload)
  end

  def cursor(position:, high_water:, kind: "changes")
    @store.send(:transaction) do |config|
      @store.send(:new_cursor!, @stream.reload, config, kind: kind, position: position, high_water: high_water).last
    end
  end

  def poll(token)
    @store.feed("stream" => "changes", "cursor" => token).body
  end

  def retained_cursor(token)
    DiscussionBridgeCmsSourceCursor.find_by!(token_digest: Digest::SHA256.hexdigest(token))
  end

  it "allocates adjacent exact sequences beyond binary64 safe integers" do
    @stream.update!(event_sequence: 9_007_199_254_740_991)
    expect([allocate.payload.fetch("event_sequence"), allocate.payload.fetch("event_sequence")])
      .to eq(%w[9007199254740992 9007199254740993])
    expect(@stream.reload.event_sequence).to eq(9_007_199_254_740_993)
  end

  it "reaches signed-64 maximum exactly and refuses another allocation without inserting" do
    @stream.update!(event_sequence: described_class::MAX_SEQUENCE - 2)
    expect([allocate.event_sequence, allocate.event_sequence])
      .to eq([described_class::MAX_SEQUENCE - 1, described_class::MAX_SEQUENCE])
    expect { allocate }.to raise_error(DiscussionBridge::CmsProtocol::Error) { |e| expect(e.code).to eq("storage_exhausted") }
    expect(@stream.source_events.count).to eq(2)
    expect(@stream.reload.event_sequence).to eq(described_class::MAX_SEQUENCE)
  end

  it "enforces unique stream sequence in the native database" do
    allocate
    expect do
      DiscussionBridgeCmsSourceEvent.transaction(requires_new: true) { insert_event(1) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(@stream.source_events.count).to eq(1)
  end

  it "returns numeric ascending sequences despite reverse physical insertion order" do
    [9_007_199_254_740_993, 9_007_199_254_740_992, 9_007_199_254_740_991].each { |n| insert_event(n) }
    @stream.update!(event_sequence: 9_007_199_254_740_993)
    page = poll(cursor(position: 9_007_199_254_740_990, high_water: 9_007_199_254_740_993))
    expect(page.fetch("items").map { |e| e.fetch("event_sequence") })
      .to eq(%w[9007199254740991 9007199254740992 9007199254740993])
    expect(retained_cursor(page.fetch("checkpoint_cursor")).position).to eq(9_007_199_254_740_993)
  end

  it "pins a multi-page drain, replays its exact page and leaves later events for the next poll" do
    105.downto(1) { |n| insert_event(n) }
    @stream.update!(event_sequence: 105)
    token = cursor(position: 0, high_water: 105)
    first = poll(token)
    expect(first.fetch("items").map { |e| e.fetch("event_sequence") }).to eq((1..100).map(&:to_s))
    expect(retained_cursor(first.fetch("checkpoint_cursor")).position).to eq(100)
    expect(retained_cursor(first.fetch("next_cursor")).high_water).to eq(105)
    expect(allocate.event_sequence).to eq(106)
    expect(poll(token)).to eq(first)
    final = poll(first.fetch("next_cursor"))
    expect(final.fetch("items").map { |e| e.fetch("event_sequence") }).to eq((101..105).map(&:to_s))
    expect(final.fetch("next_cursor")).to be_nil
    following = poll(final.fetch("checkpoint_cursor"))
    expect(following.fetch("items").map { |e| e.fetch("event_sequence") }).to eq(["106"])
  end

  it "advances an empty completed changes drain to its high-water mark" do
    @stream.update!(event_sequence: 27)
    page = poll(cursor(position: 9, high_water: 27))
    expect(page.fetch("items")).to eq([])
    expect(page.fetch("next_cursor")).to be_nil
    expect(retained_cursor(page.fetch("checkpoint_cursor")).position).to eq(27)
  end

  it "orders initial source IDs while allowing decreasing last-publication sequences" do
    [["source:z", 10], ["source:a", 20]].each do |source_id, sequence|
      intent = @stream.source_intents.create!(topic_id: topic.id, source_id: source_id, state: "active",
        current_source_revision: "revision:1")
      source = { "source_id" => source_id, "source_revision" => "revision:1", "topic_id" => topic.id.to_s,
        "topic_url" => topic.url, "title" => "Source", "content_bytes" => 0,
        "content_sha256" => Digest::SHA256.hexdigest(""), "source_created_at" => nil,
        "source_updated_at" => nil, "source_authors" => [] }
      event = insert_event(sequence, { "event_type" => "publication", "source" => source }, intent)
      intent.update!(publication_event: event)
    end
    @stream.update!(event_sequence: 20)
    page = @store.feed("stream" => "initial").body
    expect(page.fetch("items").map { |e| e.fetch("source").fetch("source_id") }).to eq(%w[source:a source:z])
    expect(page.fetch("items").map { |e| e.fetch("event_sequence") }).to eq(%w[20 10])
    expect(retained_cursor(page.fetch("checkpoint_cursor")).position).to eq(20)
  end

  it "completes an empty initial snapshot with a changes checkpoint at its horizon" do
    @stream.update!(event_sequence: 33)
    page = @store.feed("stream" => "initial").body
    expect(page.fetch("items")).to eq([])
    expect(page.fetch("next_cursor")).to be_nil
    expect(retained_cursor(page.fetch("checkpoint_cursor")).position).to eq(33)
  end
end
