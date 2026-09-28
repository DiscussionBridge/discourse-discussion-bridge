# frozen_string_literal: true

module DiscussionBridge
  class SourceRevocationFeed
    Page = Data.define(:high_water, :items, :next_cursor, :complete)

    def self.page(connection:, high_water:, cursor:, limit:)
      new(connection: connection).page(high_water: high_water, cursor: cursor, limit: limit)
    end

    def initialize(connection:)
      @connection = connection
    end

    def page(high_water:, cursor:, limit:)
      SourceRevocationRegistry.reconcile!(connection: @connection)
      high_water, maximum_id, after_id = resolve_position(high_water: high_water, cursor: cursor)
      rows = SourceRevocationRegistry.scope(connection: @connection)
        .where("id > ? AND id <= ?", after_id, maximum_id).limit(limit + 1).to_a
      page_rows = rows.first(limit)
      complete = rows.length <= limit
      next_cursor = unless complete
        SourceCursor.issue(
          kind: "revocations",
          payload: {
            "connection_id" => @connection.public_id,
            "high_water" => high_water,
            "policy_revision" => @connection.policy_revision,
            "after_id" => page_rows.last.id,
          },
        )
      end
      Page.new(
        high_water: high_water,
        items: page_rows,
        next_cursor: next_cursor,
        complete: complete,
      )
    end

    private

    def resolve_position(high_water:, cursor:)
      if cursor.present?
        payload = SourceCursor.read(cursor, kind: "revocations")
        requested = high_water.presence || payload["high_water"]
        valid = payload["connection_id"] == @connection.public_id &&
          payload["high_water"] == requested &&
          payload["policy_revision"] == @connection.policy_revision &&
          payload["after_id"].is_a?(Integer) && payload["after_id"] >= 0
        raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch" unless valid

        maximum_id = read_high_water(requested)
        return [requested, maximum_id, payload["after_id"]]
      end

      if high_water.present?
        return [high_water, read_high_water(high_water), 0]
      end

      maximum_id = SourceRevocationRegistry.scope(connection: @connection).maximum(:id).to_i
      issued = SourceCursor.issue(
        kind: "revocation_high_water",
        payload: {
          "connection_id" => @connection.public_id,
          "policy_revision" => @connection.policy_revision,
          "maximum_id" => maximum_id,
        },
      )
      [issued, maximum_id, 0]
    end

    def read_high_water(value)
      payload = SourceCursor.read(value, kind: "revocation_high_water")
      valid = payload["connection_id"] == @connection.public_id &&
        payload["policy_revision"] == @connection.policy_revision &&
        payload["maximum_id"].is_a?(Integer) && payload["maximum_id"] >= 0
      raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch" unless valid

      payload["maximum_id"]
    end
  end
end
