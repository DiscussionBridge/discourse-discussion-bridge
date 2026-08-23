# frozen_string_literal: true

module DiscussionBridge
  class EmbedRouteAttestation
    PURPOSE = "discussion-bridge-comments-only-embed-route"
    MAX_AGE = 12.hours

    def self.issue(mapping:, class_name:)
      verifier.generate(
        {
          "mapping_id" => mapping.id,
          "topic_id" => mapping.topic_id,
          "mapping_updated_at" => mapping.updated_at.utc.iso8601(6),
          "class_name" => class_name,
        },
        purpose: PURPOSE,
        expires_in: MAX_AGE,
      )
    end

    def self.verify(token)
      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      return unless payload.is_a?(Hash)

      mapping =
        DiscussionBridgeConnection.find_by(
          id: payload["mapping_id"],
          topic_id: payload["topic_id"],
          state: "complete",
        )
      return unless mapping
      return unless mapping.updated_at.utc.iso8601(6) == payload["mapping_updated_at"]

      class_name = payload["class_name"].to_s
      return unless class_name.match?(CommentsOnlyPresenter::CLASS_NAME_PATTERN)
      return if class_name.split.exclude?(CommentsOnlyPresenter::CSS_CLASS)

      { mapping: mapping, class_name: class_name }
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def self.verifier
      Rails.application.message_verifier(:discussion_bridge_embed_route)
    end

    private_class_method :verifier
  end
end
