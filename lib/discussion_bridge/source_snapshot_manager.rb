# frozen_string_literal: true

module DiscussionBridge
  class SourceSnapshotManager
    BUILD_BATCH_SIZE = SourcePublicationProtocol::MAXIMUM_LIMIT
    CLEANUP_BATCH_SIZE = SourcePublicationProtocol::MAXIMUM_LIMIT

    Page = Data.define(:snapshot, :items, :next_cursor, :complete)

    def self.page(connection:, snapshot_id:, cursor:, limit:)
      new(connection: connection).page(snapshot_id: snapshot_id, cursor: cursor, limit: limit)
    end

    def initialize(connection:)
      @connection = connection
    end

    def page(snapshot_id:, cursor:, limit:)
      snapshot, after_ordinal = resolve_snapshot(snapshot_id: snapshot_id, cursor: cursor)
      raise AdapterRequestBoundary::Error, "snapshot_expired" if snapshot.expires_at <= Time.zone.now

      rows = snapshot_rows(snapshot, after_ordinal, limit)
      if rows.length <= limit && !snapshot.build_complete
        build_next_batch!(snapshot)
        snapshot.reload
        rows = snapshot_rows(snapshot, after_ordinal, limit)
      end
      page_rows = rows.first(limit)
      denied = page_rows.any? do |row|
        SourceRevisionMaterializer.unavailability_reason(
          record: row.source_revision.bridge_record,
          connection: @connection,
        )
      end
      raise AdapterRequestBoundary::Error, "scope_denied" if denied
      complete = snapshot.build_complete && rows.length <= limit
      next_cursor = unless complete
        SourceCursor.issue(
          kind: "inventory",
          payload: {
            "connection_id" => @connection.public_id,
            "snapshot" => snapshot.snapshot_id,
            "policy_revision" => snapshot.policy_revision,
            "after_ordinal" => page_rows.last&.ordinal || after_ordinal,
          },
        )
      end
      now = Time.zone.now
      snapshot.update!(
        last_read_at: now,
        expires_at: now + SourcePublicationProtocol::SNAPSHOT_RETENTION_SECONDS,
        completed_at: complete ? (snapshot.completed_at || now) : snapshot.completed_at,
      )
      Page.new(snapshot: snapshot, items: page_rows, next_cursor: next_cursor, complete: complete)
    end

    private

    def snapshot_rows(snapshot, after_ordinal, limit)
      snapshot.snapshot_items.includes(:source_revision)
        .where("ordinal > ?", after_ordinal).order(:ordinal).limit(limit + 1).to_a
    end

    def resolve_snapshot(snapshot_id:, cursor:)
      return resume_snapshot(snapshot_id: snapshot_id, cursor: cursor) if cursor.present?

      if snapshot_id.present?
        snapshot = @connection.source_snapshots.find_by(snapshot_id: snapshot_id)
        raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch" unless snapshot
        raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch" unless
          snapshot.policy_revision == @connection.policy_revision
        return [snapshot, 0]
      end

      [create_snapshot!, 0]
    end

    def resume_snapshot(snapshot_id:, cursor:)
      payload = SourceCursor.read(cursor, kind: "inventory")
      requested = snapshot_id.presence || payload["snapshot"]
      valid = payload["connection_id"] == @connection.public_id &&
        payload["snapshot"] == requested &&
        payload["policy_revision"] == @connection.policy_revision &&
        payload["after_ordinal"].is_a?(Integer) && payload["after_ordinal"] >= 0
      raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch" unless valid

      snapshot = @connection.source_snapshots.find_by(snapshot_id: requested)
      raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch" unless
        snapshot && snapshot.policy_revision == payload["policy_revision"]

      [snapshot, payload["after_ordinal"]]
    end

    def create_snapshot!
      snapshot = nil
      DiscussionBridgeSourceSnapshot.transaction do
        @connection.lock!
        now = Time.zone.now
        cleanup_expired_snapshots!(now)
        snapshot = @connection.source_snapshots
          .where(policy_revision: @connection.policy_revision)
          .where("expires_at > ?", now).order(id: :desc).first
        snapshot = nil if snapshot&.build_complete && source_changed_after?(snapshot)
        snapshot ||= @connection.source_snapshots.create!(
          snapshot_id: "dbs_#{SecureRandom.hex(16)}",
          policy_revision: @connection.policy_revision,
          source_high_water_record_id: source_records.maximum(:id).to_i,
          scan_cursor_record_id: 0,
          build_complete: false,
          last_read_at: now,
          expires_at: now + SourcePublicationProtocol::SNAPSHOT_RETENTION_SECONDS,
        )
      end
      snapshot
    end

    def source_changed_after?(snapshot)
      completed_at = snapshot.completed_at
      return true unless completed_at

      records = source_records.reorder(nil)
      records.where("discussion_bridge_bridge_records.id > ?", snapshot.source_high_water_record_id).exists? ||
        records.where("discussion_bridge_bridge_records.updated_at > ?", completed_at).exists? ||
        Topic.unscoped.where(id: records.select(:topic_id)).where("topics.updated_at > ?", completed_at).exists? ||
        Post.unscoped.where(topic_id: records.select(:topic_id), post_number: 1)
          .where("posts.updated_at > ?", completed_at).exists?
    end

    def build_next_batch!(snapshot)
      @connection.with_lock do
        snapshot.lock!
        next if snapshot.build_complete

        records = source_records.where("discussion_bridge_bridge_records.id > ?", snapshot.scan_cursor_record_id)
          .where("discussion_bridge_bridge_records.id <= ?", snapshot.source_high_water_record_id)
          .limit(BUILD_BATCH_SIZE).to_a
        ordinal = snapshot.snapshot_items.maximum(:ordinal).to_i
        records.each do |record|
          result = SourceRevocationRegistry.reconcile_record!(record: record, connection: @connection)
          next unless result&.revision

          ordinal += 1
          snapshot.snapshot_items.create!(source_revision: result.revision, ordinal: ordinal)
        end
        last_scanned = records.last&.id || snapshot.source_high_water_record_id
        snapshot.update!(
          scan_cursor_record_id: last_scanned,
          build_complete: records.length < BUILD_BATCH_SIZE ||
            last_scanned >= snapshot.source_high_water_record_id,
        )
      end
    end

    def cleanup_expired_snapshots!(now)
      expired = @connection.source_snapshots.where("expires_at <= ?", now).order(:id).first
      return unless expired

      item_ids = expired.snapshot_items.order(:id).limit(CLEANUP_BATCH_SIZE).pluck(:id)
      DiscussionBridgeSourceSnapshotItem.where(id: item_ids).delete_all
      expired.destroy! unless expired.snapshot_items.exists?
    end

    def source_records
      DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(direction: "from_discourse")
        .where(
          discussion_bridge_content_bindings: {
            content_connection_id: @connection.id,
            role: "presentation",
            state: "active",
          },
        )
        .distinct.order(:id)
    end
  end
end
