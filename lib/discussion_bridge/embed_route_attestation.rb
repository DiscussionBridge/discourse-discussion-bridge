# frozen_string_literal: true

require "time"

module DiscussionBridge
  class EmbedRouteAttestation
    PURPOSE = "discussion-bridge-comments-only-embed-route"
    MAX_AGE = 12.hours
    MAX_TOKEN_BYTES = 4096

    def self.issue(mapping:, class_name:)
      unless CommentsOnlyPresenter.valid_final_class_name?(class_name)
        raise ArgumentError, "invalid attestation class"
      end

      verifier.generate(
        {
          "mapping_id" => mapping.id,
          "record_type" => mapping.is_a?(DiscussionBridgeBridgeRecord) ? "bridge_record" : "legacy_mapping",
          "topic_id" => mapping.topic_id,
          "mapping_updated_at" => mapping.updated_at.utc.iso8601(6),
          "class_name" => class_name,
          "issued_at" => Time.zone.now.utc.iso8601(6),
        },
        purpose: PURPOSE,
      )
    end

    def self.verify(token)
      payload = authenticated_payload(token)
      return unless live_payload?(payload)

      mapping = if payload["record_type"] == "bridge_record"
        DiscussionBridgeBridgeRecord.find_by(
          id: payload["mapping_id"], topic_id: payload["topic_id"], state: "healthy",
        )
      else
        DiscussionBridgeConnection.find_by(
          id: payload["mapping_id"], topic_id: payload["topic_id"], state: "complete",
        )
      end
      return unless mapping
      return unless mapping.updated_at.utc.iso8601(6) == payload["mapping_updated_at"]

      class_name = payload["class_name"]
      return unless CommentsOnlyPresenter.valid_final_class_name?(class_name)

      { mapping: mapping, class_name: class_name }
    end

    def self.authenticated_payload(token)
      return if token.to_s.bytesize > MAX_TOKEN_BYTES

      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      payload if payload.is_a?(Hash)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def self.live_payload?(payload, now: Time.zone.now)
      return false unless payload.is_a?(Hash)

      issued_at = Time.iso8601(payload["issued_at"].to_s)
      issued_at <= now && issued_at >= now - MAX_AGE
    rescue ArgumentError
      false
    end

    def self.verifier
      Rails.application.message_verifier(:discussion_bridge_embed_route)
    end

    private_class_method :verifier
  end
end
