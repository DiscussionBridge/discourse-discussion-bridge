# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsSourceStore do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @now = Time.current
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS source native author fixture",
        platform: "hugo",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @policy = {
      "policy_revision" => SecureRandom.uuid,
      "enabled" => true,
      "selection" => "all_public",
      "category_ids" => [],
      "include_topic_ids" => [],
      "exclude_topic_ids" => [],
      "include_unlisted" => false,
      "publication_kind" => "static",
      "presentation_mode" => "simple",
      "author_ids" => [],
      "taxonomy_ids" => [],
      "existing_record_adoption" => "disabled",
      "adoptable_resource_ids" => [],
    }
    @connection.update!(
      cms_configuration: {
        "profile" => "hugo",
        "destination_origin" => "https://site.example",
        "publication_lane" => "news",
        "native_capabilities" => {
          "native_revision" => "native:1",
          "supported_presentations" => ["simple"],
          "publication_kind" => "static",
          "complete_content_supported" => true,
        },
        "policy" => @policy,
      },
    )
    @store = described_class.new(@connection, clock: -> { @now })
  end

  def rejected(code, &block)
    expect(&block).to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq(code)
    }
  end

  def initial
    @store.feed("stream" => "initial").body
  end

  def captured
    @store.intent("topic:#{topic.id}")
  end

  it "does not discover sources or create intents, mappings or work through GET" do
    rejected("native_service_unavailable") { initial }
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsMapping.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "requires completed receiver scan rather than a partial discovered source set" do
    @store.refresh_topic!(topic.id)
    expect(captured).to be_present
    rejected("native_service_unavailable") { initial }
    @store.refresh_all!
    expect(initial.fetch("items").size).to eq(1)
    expect(DiscussionBridgeCmsSourceStream.first.scan_state).to eq("complete")
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(1)
    expect(DiscussionBridgeCmsMapping.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "captures native creator identity, exact dates and complete immutable cooked bytes" do
    @store.refresh_all!
    event = initial.fetch("items").first
    source = event.fetch("source")
    expect(source.fetch("source_id")).to eq("topic:#{topic.id}")
    expect(source.fetch("topic_id")).to eq(topic.id.to_s)
    expect(event.fetch("event_sequence")).to eq("1")
    expect(source.fetch("source_authors").first.fetch("id")).to eq(admin.id.to_s)
    expect(source.fetch("source_created_at")).to eq(
      DiscussionBridge::CmsProtocol.instant(first_post.created_at),
    )
    expect(source.fetch("source_updated_at")).to eq(
      DiscussionBridge::CmsProtocol.instant(first_post.updated_at),
    )
    revision = captured.source_revisions.first
    expect(revision.content_bytes_blob.b).to eq(first_post.reload.cooked.b)
    expect(source.fetch("content_sha256")).to eq(Digest::SHA256.hexdigest(first_post.cooked))
    expect { revision.update!(source_metadata: {}) }.to raise_error(ActiveRecord::RecordNotSaved)
    expect { revision.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  it "uses private v2 revisions and stable creator IDs without altering public legacy source keys" do
    legacy = DiscussionBridge::SourceEdition.for_topic(topic.id).source
    expect(legacy.fetch(:author).keys).to contain_exactly(:username, :name, :profile_url)
    snapshot = @store.capture_snapshot(topic)
    expect(snapshot.metadata.fetch("source_revision")).not_to eq(legacy.fetch(:edition))
    expect(snapshot.metadata.fetch("source_authors").first.fetch("id")).to eq(admin.id.to_s)
    admin.update!(name: "A changed native byline")
    changed = @store.capture_snapshot(topic)
    expect(changed.metadata.fetch("source_revision")).not_to eq(
      snapshot.metadata.fetch("source_revision"),
    )
    expect(changed.metadata.fetch("source_authors").first.fetch("id")).to eq(admin.id.to_s)
  end

  it "keeps exact retries harmless and source/wiki edits append new pinned revisions" do
    @store.refresh_all!
    intent = captured
    old_revision = intent.current_source_revision
    old_body = intent.source_revisions.first.content_bytes_blob.b
    @store.refresh_topic!(topic.id)
    expect(intent.reload.source_revisions.count).to eq(1)
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(1)
    first_post.update!(
      raw: "A wiki source edit",
      cooked: "<p>A wiki source edit</p>",
      wiki: true,
      version: first_post.version + 1,
      updated_at: @now + 10,
    )
    @store.refresh_topic!(topic.id)
    expect(intent.reload.current_source_revision).not_to eq(old_revision)
    expect(intent.source_revisions.count).to eq(2)
    expect(
      intent.source_revisions.find_by!(source_revision: old_revision).content_bytes_blob.b,
    ).to eq(old_body)
    expect(DiscussionBridgeCmsSourceEvent.order(:event_sequence).pluck(:event_sequence)).to eq(
      [1, 2],
    )
    expect(intent.source_revisions.last.source_metadata.fetch("source_updated_at")).to eq(
      DiscussionBridge::CmsProtocol.instant(first_post.updated_at),
    )
  end

  it "does not make a reply or topic bump a first-post source revision or modified time" do
    @store.refresh_all!
    revision = captured.current_source_revision
    modified = captured.source_revisions.first.source_metadata.fetch("source_updated_at")
    Fabricate(:post, topic: topic, user: admin, post_number: 2)
    topic.update!(updated_at: @now + 60)
    @store.refresh_topic!(topic.id)
    expect(captured.current_source_revision).to eq(revision)
    expect(captured.source_revisions.first.source_metadata.fetch("source_updated_at")).to eq(
      modified,
    )
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(1)
  end

  it "assembles complete UTF8 source through exact byte chunks and permits empty EOF" do
    body = "<p>" + "😀" * 20_000 + "</p>"
    # Install the exact persisted cooked fixture without a raw edit triggering
    # native recooking; production capture only reads these stored native bytes.
    first_post.update_columns(cooked: body)
    expect(first_post.reload.cooked.b).to eq(body.b)
    @store.refresh_all!
    revision = captured.current_source_revision
    offset = 0
    assembled = "".b
    loop do
      response = @store.content(captured.source_id, revision, "offset" => offset).body
      bytes = Base64.strict_decode64(response.fetch("content_base64"))
      expect(bytes.bytesize).to be <= 32_768
      assembled << bytes
      break if response.fetch("next_offset").nil?
      expect(response.fetch("next_offset")).to eq(offset + bytes.bytesize)
      offset = response.fetch("next_offset")
    end
    expect(assembled).to eq(body.b)
    expect(assembled.force_encoding(Encoding::UTF_8)).to be_valid_encoding
    eof = @store.content(captured.source_id, revision, "offset" => body.bytesize).body
    expect(eof.fetch("content_base64")).to eq("")
    expect(eof.fetch("next_offset")).to be_nil
    rejected("invalid_field") do
      @store.content(captured.source_id, revision, "offset" => body.bytesize + 1)
    end
  end

  it "keeps content available beyond thirty days with no incidental GC" do
    @store.refresh_all!
    revision = captured.current_source_revision
    @now += 40.days
    expect(@store.content(captured.source_id, revision).body.fetch("source_revision")).to eq(
      revision,
    )
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(1)
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(1)
  end

  it "fails closed on current native visibility before an observer can record revocation" do
    @store.refresh_all!
    revision = captured.current_source_revision
    topic.update!(visible: false)
    rejected("source_ineligible") { @store.content(captured.source_id, revision) }
    rejected("cursor_scope_changed") { initial }
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(1)
  end

  it "records owned revocations without private body, title or authors and retains receipts" do
    @store.refresh_all!
    page = initial
    revision = captured.current_source_revision
    private_title = "New private native title"
    topic.update!(title: private_title, visible: false)
    @store.refresh_topic!(topic.id)
    expect(captured.state).to eq("revoked")
    revocation = DiscussionBridgeCmsSourceEvent.order(:event_sequence).last.payload
    expect(revocation.fetch("event_type")).to eq("revocation")
    expect(revocation.fetch("last_source_revision")).to eq(revision)
    expect(revocation.keys).to contain_exactly(
      "event_type",
      "event_id",
      "event_sequence",
      "source_id",
      "last_source_revision",
      "reason",
    )
    expect(revocation.to_json).not_to include(private_title, first_post.cooked, admin.username)
    rejected("cursor_scope_changed") do
      @store.feed("stream" => "changes", "cursor" => page.fetch("checkpoint_cursor"))
    end
    expect(initial.fetch("items")).to eq([])
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(1)
    expect(DiscussionBridgeCmsMapping.count).to eq(0)
  end

  it "does not export a native shared draft" do
    SharedDraft.create!(topic_id: topic.id, category_id: topic.category_id)
    @store.refresh_all!
    expect(initial.fetch("items")).to eq([])
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
  end

  it "records attention instead of silently truncating unrepresentable source authors" do
    snapshot = @store.capture_snapshot(topic)
    metadata = snapshot.metadata.deep_dup
    metadata["source_authors"] = 21.times.map { |id| { "id" => id.to_s, "name" => "Author #{id}" } }
    @store.stubs(:capture_snapshot_locked).returns(
      described_class::Snapshot.new(metadata: metadata, body: snapshot.body),
    )
    @store.refresh_all!
    expect(captured.state).to eq("attention")
    expect(captured.attention_code).to eq("metadata_unavailable")
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(0)
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(0)
    rejected("metadata_unavailable") { initial }
  end

  it "does not reuse an immutable revision for altered metadata or body" do
    @store.refresh_all!
    snapshot = @store.capture_snapshot(topic)
    metadata = snapshot.metadata.merge("title" => "Different title with claimed identical revision")
    @store.stubs(:capture_snapshot_locked).returns(
      described_class::Snapshot.new(metadata: metadata, body: snapshot.body),
    )
    @store.refresh_topic!(topic.id)
    expect(captured.state).to eq("attention")
    expect(captured.attention_code).to eq("revision_conflict")
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(1)
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(1)
  end

  it "pins initial pagination and returns identical continuation bodies after later edits" do
    100.times do
      native_topic = Fabricate(:topic, user: admin)
      Fabricate(:post, topic: native_topic, user: admin, post_number: 1)
    end
    @store.refresh_all!
    page = initial
    expect(page.fetch("items").size).to eq(100)
    expect(page.fetch("checkpoint_cursor")).to be_nil
    continuation = { "stream" => "initial", "cursor" => page.fetch("next_cursor") }
    final = @store.feed(continuation).body
    expect(final.fetch("items").size).to eq(1)
    expect(final.fetch("next_cursor")).to be_nil
    first_post.update!(
      raw: "Later edit",
      cooked: "<p>Later edit</p>",
      version: first_post.version + 1,
    )
    @store.refresh_topic!(topic.id)
    expect(@store.feed(continuation).body).to eq(final)
    ids =
      (page.fetch("items") + final.fetch("items")).map do |item|
        item.fetch("source").fetch("source_id")
      end
    expect(ids).to eq(ids.sort)
    changes = @store.feed("stream" => "changes", "cursor" => final.fetch("checkpoint_cursor")).body
    expect(changes.fetch("items").size).to eq(1)
    expect(changes.fetch("items").first.fetch("source").fetch("source_revision")).to eq(
      captured.current_source_revision,
    )
  end

  it "advances empty change checkpoints and never rewinds or splices expired scope" do
    @store.refresh_all!
    checkpoint = initial.fetch("checkpoint_cursor")
    empty = @store.feed("stream" => "changes", "cursor" => checkpoint).body
    expect(empty.fetch("items")).to eq([])
    expect(empty.fetch("next_cursor")).to be_nil
    expect(empty.fetch("checkpoint_cursor")).to be_present
    @now += 86_401
    rejected("cursor_expired") do
      @store.feed("stream" => "changes", "cursor" => empty.fetch("checkpoint_cursor"))
    end
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(1)
  end

  it "invalidates cursors immediately on stored policy/scope changes before a new scan" do
    @store.refresh_all!
    checkpoint = initial.fetch("checkpoint_cursor")
    config = @connection.cms_configuration.deep_dup
    config.fetch("policy")["policy_revision"] = SecureRandom.uuid
    @connection.update!(cms_configuration: config)
    rejected("cursor_scope_changed") { @store.feed("stream" => "changes", "cursor" => checkpoint) }
    rejected("native_service_unavailable") { initial }
  end

  it "does not let another connection read body or pagination receipts" do
    @store.refresh_all!
    checkpoint = initial.fetch("checkpoint_cursor")
    other, =
      DiscussionBridgeContentConnection.issue!(
        @connection
          .attributes
          .slice(
            "platform",
            "allowed_origins",
            "allowed_directions",
            "allowed_lanes",
            "cms_configuration",
          )
          .merge("name" => "Other source owner"),
      )
    other_store = described_class.new(other, clock: -> { @now })
    other_store.refresh_all!
    rejected("cursor_scope_changed") do
      other_store.feed("stream" => "changes", "cursor" => checkpoint)
    end
    unknown_source = "topic:9223372036854775807"
    rejected("resource_not_found") do
      other_store.content(unknown_source, captured.current_source_revision)
    end
  end

  it "rechecks rotated secrets and disabled publication before creating cursor receipts" do
    @store.refresh_all!
    authenticated =
      described_class.new(
        @connection,
        clock: -> { @now },
        authenticated_secret_digest: @connection.secret_digest,
      )
    @connection.rotate_secret!
    rejected("authentication_failed") { authenticated.feed("stream" => "initial") }
    expect(DiscussionBridgeCmsSourceCursor.count).to eq(0)
    @connection.update!(enabled: false)
    rejected("connection_disabled") { initial }
    expect(DiscussionBridgeCmsSourceCursor.count).to eq(0)
  end

  it "refuses counter exhaustion without wrapping or advertising new publication" do
    @store.refresh_all!
    stream = DiscussionBridgeCmsSourceStream.first
    stream.update!(event_sequence: described_class::MAX_SEQUENCE)
    first_post.update!(
      raw: "New revision at exhaustion",
      cooked: "<p>New revision at exhaustion</p>",
    )
    @store.refresh_topic!(topic.id)
    expect(stream.reload.event_sequence).to eq(described_class::MAX_SEQUENCE)
    expect(captured.state).to eq("attention")
    expect(captured.attention_code).to eq("storage_exhausted")
    expect(DiscussionBridgeCmsSourceEvent.count).to eq(1)
    rejected("storage_exhausted") { initial }
  end
end
