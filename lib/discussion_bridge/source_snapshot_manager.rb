# frozen_string_literal: true

module DiscussionBridge
  class SourceSnapshotManager
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

      rows = snapshot.snapshot_items.includes(:source_revision)
        .where("ordinal > ?", after_ordinal).order(:ordinal).limit(limit + 1).to_a
      page_rows = rows.first(limit)
      denied = page_rows.any? do |row|
        SourceRevisionMaterializer.unavailability_reason(
          record: row.source_revision.bridge_record,
          connection: @connection,
        )
      end
      raise AdapterRequestBoundary::Error, "scope_denied" if denied
      complete = rows.length <= limit
      next_cursor = unless complete
        SourceCursor.issue(
          kind: "inventory",
          payload: {
            "connection_id" => @connection.public_id,
            "snapshot" => snapshot.snapshot_id,
            "policy_revision" => snapshot.policy_revision,
            "after_ordinal" => page_rows.last.ordinal,
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
      SourceRevocationRegistry.reconcile!(connection: @connection)
      snapshot = nil
      DiscussionBridgeSourceSnapshot.transaction do
        @connection.lock!
        now = Time.zone.now
        snapshot = @connection.source_snapshots.create!(
          snapshot_id: "dbs_#{SecureRandom.hex(16)}",
          policy_revision: @connection.policy_revision,
          last_read_at: now,
          expires_at: now + SourcePublicationProtocol::SNAPSHOT_RETENTION_SECONDS,
        )
        ordinal = 0
        source_records.find_each do |record|
          result = SourceRevisionMaterializer.call(record: record, connection: @connection)
          next if result.reason

          ordinal += 1
          snapshot.snapshot_items.create!(source_revision: result.revision, ordinal: ordinal)
        end
      end
      snapshot
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
