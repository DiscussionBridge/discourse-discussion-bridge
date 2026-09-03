# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class AdapterFeedSnapshot
    PURPOSE = "discussion-bridge-adapter-feed"
    MAX_TOKEN_BYTES = 8_192

    Snapshot = Data.define(:digest, :total)

    def self.capture(relation)
      rows = relation.reorder("discussion_bridge_bridge_records.id ASC").pluck(
        "discussion_bridge_bridge_records.id",
        "discussion_bridge_bridge_records.updated_at",
        "discussion_bridge_content_bindings.id",
        "discussion_bridge_content_bindings.updated_at",
      )
      canonical = rows.map { |row| row.map { |value| value.respond_to?(:utc) ? value.utc.iso8601(6) : value.to_s }.join(":" ) }.join("\n")
      Snapshot.new(digest: Digest::SHA256.hexdigest(canonical), total: rows.map(&:first).uniq.length)
    end

    def self.issue(connection:, snapshot:)
      verifier.generate(
        { "connection_id" => connection.id, "digest" => snapshot.digest, "total" => snapshot.total },
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
