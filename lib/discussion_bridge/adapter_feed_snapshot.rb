# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class AdapterFeedSnapshot
    PURPOSE = "discussion-bridge-adapter-feed"
    MAX_TOKEN_BYTES = 8_192
    BATCH_SIZE = 100

    Snapshot = Data.define(:digest, :total)

    def self.capture(relation)
      # The snapshot still describes the complete authorized inventory, but its
      # census must not retain every mapping and source edition in memory.
      records = relation.except(:includes, :preload, :eager_load, :order)
      digest = Digest::SHA256.new
      total = 0
      last_id = 0
      first_row = true
      loop do
        ids =
          records
            .where("discussion_bridge_bridge_records.id > ?", last_id)
            .reorder("discussion_bridge_bridge_records.id ASC")
            .limit(BATCH_SIZE)
            .distinct
            .pluck("discussion_bridge_bridge_records.id")
        break if ids.empty?

        rows =
          records
            .where(discussion_bridge_bridge_records: { id: ids })
            .reorder(
              "discussion_bridge_bridge_records.id ASC",
              "discussion_bridge_content_bindings.id ASC",
            )
            .pluck(
              "discussion_bridge_bridge_records.id",
              "discussion_bridge_bridge_records.updated_at",
              "discussion_bridge_content_bindings.id",
              "discussion_bridge_content_bindings.updated_at",
              "discussion_bridge_bridge_records.direction",
              "discussion_bridge_bridge_records.topic_id",
              "discussion_bridge_bridge_records.resource_id",
            )
        source_editions =
          SourceEdition.editions(rows.filter_map { |row| row[5] if row[4] == "from_discourse" })
        withdrawal_editions =
          SourceEdition.withdrawal_editions(
            rows.filter_map do |row|
              if row[4] == "from_discourse" && !source_editions.key?(row[5])
                [row[6], row[5], row[1]]
              end
            end,
          )
        rows.each do |row|
          canonical =
            (row + [source_editions[row[5]] || withdrawal_editions[row[6]]])
              .map { |value| value.respond_to?(:utc) ? value.utc.iso8601(6) : value.to_s }
              .join(":")
          digest << "\n" unless first_row
          digest << canonical
          first_row = false
        end
        total += ids.length
        last_id = ids.last
      end
      Snapshot.new(digest: digest.hexdigest, total: total)
    end

    def self.issue(connection:, snapshot:)
      verifier.generate(
        {
          "connection_id" => connection.id,
          "digest" => snapshot.digest,
          "total" => snapshot.total,
        },
        purpose: PURPOSE,
      )
    end

    def self.valid?(token, connection:, snapshot:)
      return false if token.to_s.bytesize > MAX_TOKEN_BYTES

      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      payload.is_a?(Hash) && payload["connection_id"] == connection.id &&
        payload["digest"] == snapshot.digest && payload["total"] == snapshot.total
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      false
    end

    def self.verifier
      Rails.application.message_verifier(:discussion_bridge_adapter_feed)
    end

    private_class_method :verifier
  end
end
