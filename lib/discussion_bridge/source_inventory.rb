# frozen_string_literal: true

module DiscussionBridge
  class SourceInventory
    RETENTION_SECONDS = 2_592_000
    MAX_RESPONSE_BYTES = 262_144
    CURSOR_PURPOSE = "discussion-bridge-source-inventory"
    MAX_TOKEN_BYTES = 4096

    def initialize(connection:, query:, correlation_id:)
      @connection = connection
      @query = query
      @correlation_id = correlation_id
    end

    # Called under the current authenticated connection lock/transaction. The
    # cut selects immutable observations, not records materialized later.
    def page
      limit = parse_limit
      policy = policy_revision
      cursor = decode_cursor(policy)
      snapshot = find_snapshot(cursor, policy)
      snapshot.with_lock do
        fail_with("snapshot_expired") if snapshot.last_read_at < Time.now.utc - RETENTION_SECONDS
        fail_with("cursor_snapshot_mismatch") unless snapshot.policy_revision == policy
        position = cursor ? cursor.fetch("position") : 0
        starting_position = position
        fail_with("cursor_snapshot_mismatch") unless position.between?(0, snapshot.observation_cut)
        entries = observed.where("id > ? AND id <= ?", position, snapshot.observation_cut).order(:id).limit(limit).to_a
        items = []
        entries.each do |entry|
          item = item_at_cut(entry, snapshot.observation_cut)
          candidate = item ? items + [item] : items
          # Leave an over-budget item unconsumed so the next page can emit it.
          if item && candidate.to_json.bytesize > MAX_RESPONSE_BYTES - 8192
            fail_with("content_unsupported") if position == starting_position
            break
          end
          items = candidate
          position = entry.id
        end
        remaining = observed.where("id > ? AND id <= ?", position, snapshot.observation_cut).exists?
        value = { snapshot: snapshot.public_id, policy_revision: snapshot.policy_revision, items: items,
          next_cursor: remaining ? issue_cursor(snapshot, position) : nil, complete: !remaining,
          correlation_id: @correlation_id }
        fail_with("content_unsupported") if value.to_json.bytesize > MAX_RESPONSE_BYTES
        snapshot.update!(last_read_at: Time.now.utc)
        value
      end
    end

    private

    def observed
      DiscussionBridgeSourceInventoryEntry.where(content_connection_id: @connection.id)
    end

    def policy_revision
      scope = { "platform" => @connection.platform,
        "directions" => Array(@connection.allowed_directions).sort,
        "lanes" => Array(@connection.allowed_lanes).sort,
        "origins" => Array(@connection.allowed_origins).sort }
      "policy:#{NativeSourceRevisionCapture.fingerprint(scope)}"
    end

    def parse_limit
      return 25 unless @query.key?("limit")
      raw = @query["limit"]
      fail_with("validation_failed") unless raw.is_a?(String) && /\A[1-9]\d{0,2}\z/.match?(raw)
      value = Integer(raw)
      fail_with("validation_failed") unless value.between?(1, 100)
      value
    end

    def decode_cursor(policy)
      return nil unless @query.key?("cursor")
      raw = @query["cursor"]
      fail_with("validation_failed") unless raw.is_a?(String) && raw.bytesize.between?(1, MAX_TOKEN_BYTES)
      value = verifier.verified(raw, purpose: CURSOR_PURPOSE)
      fields = %w[connection_id snapshot policy_revision position]
      fail_with("validation_failed") unless value.is_a?(Hash) && value.keys.sort == fields.sort &&
        value["position"].is_a?(Integer)
      fail_with("cursor_snapshot_mismatch") unless value["connection_id"] == @connection.public_id &&
        value["policy_revision"] == policy && value["snapshot"] == @query["snapshot"]
      value
    end

    def find_snapshot(cursor, policy)
      unless @query.key?("snapshot")
        fail_with("cursor_snapshot_mismatch") if cursor
        now = Time.now.utc
        return DiscussionBridgeSourceInventorySnapshot.create!(content_connection: @connection,
          public_id: "dbs_#{SecureRandom.hex(16)}", policy_revision: policy,
          observation_cut: observed.order(id: :desc).limit(1).pick(:id) || 0,
          established_at: now, last_read_at: now)
      end
      raw = @query["snapshot"]
      fail_with("validation_failed") unless raw.is_a?(String) && /\Adbs_[a-f0-9]{32}\z/.match?(raw)
      snapshot = DiscussionBridgeSourceInventorySnapshot.find_by(content_connection_id: @connection.id, public_id: raw)
      fail_with("snapshot_expired") unless snapshot
      snapshot
    end

    def item_at_cut(entry, cut)
      # At most limit immutable observations are scanned. Superseded or private
      # entries still advance the real position; changed token text is not progress.
      return nil if observed.where(bridge_record_id: entry.bridge_record_id).where("id > ? AND id <= ?", entry.id, cut).exists?
      fail_with("reconciliation_required") unless SourceInventoryObservation.context_digest(entry.attributes) == entry.context_digest
      topic = Topic.lock.find_by(id: entry.topic_id)
      return nil unless topic && topic.deleted_at.nil? && !topic.private_message? && Guardian.new.can_see?(topic) &&
        Post.unscoped.where(topic_id: topic.id, post_number: 1, deleted_at: nil).exists?
      record = DiscussionBridgeBridgeRecord.lock.find(entry.bridge_record_id)
      fail_with("reconciliation_required") unless record.direction == "from_discourse" &&
        record.resource_id == entry.resource_id && record.topic_id == entry.topic_id && record.lane == entry.lane
      binding = record.content_bindings.find_by(id: entry.content_binding_id, content_connection_id: @connection.id,
        role: "presentation", state: "active")
      return nil unless binding
      fail_with("reconciliation_required") unless binding.public_id == entry.binding_public_id &&
        binding.canonical_url == entry.canonical_url
      return nil unless @connection.allows_lane?(record.lane) && @connection.allows_origin?(binding.canonical_url)
      matches = DiscussionBridgeBridgeRecord.joins(:content_bindings).where(direction: "from_discourse", topic_id: topic.id,
        discussion_bridge_content_bindings: { content_connection_id: @connection.id, role: "presentation", state: "active" }).distinct.limit(2).pluck(:id)
      fail_with("reconciliation_required") unless matches == [record.id]
      capture = DiscussionBridgeNativeSourceRevision.select(:id, :bridge_record_id, :revision).find(entry.native_source_revision_id)
      fail_with("reconciliation_required") unless capture.bridge_record_id == record.id
      SourceRevisionTransport.new(record: record, binding: binding, revision: capture.revision).inventory_item
    end

    def issue_cursor(snapshot, position)
      verifier.generate({ "connection_id" => @connection.public_id, "snapshot" => snapshot.public_id,
        "policy_revision" => snapshot.policy_revision, "position" => position }, purpose: CURSOR_PURPOSE)
    end

    def verifier
      Rails.application.message_verifier(:discussion_bridge_source_inventory)
    end

    def fail_with(code)
      raise AdapterRequestBoundary::Error.new(code)
    end
  end
end
