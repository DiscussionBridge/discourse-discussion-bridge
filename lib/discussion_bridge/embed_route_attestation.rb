# frozen_string_literal: true

module DiscussionBridge
  class EmbedRouteAttestation
    PURPOSE = "discussion-bridge-comments-only-embed-route"
    MAX_AGE = 12.hours
    TOKEN_PATTERN = /\A([1-9]\d*)\.(.+)\z/

    def self.issue(mapping:, class_name:)
      payload = {
        "mapping_id" => mapping.id,
        "topic_id" => mapping.topic_id,
        "mapping_updated_at" => mapping.updated_at.to_i,
        "class_name" => class_name,
      }
      signed = verifier.generate(payload, purpose: PURPOSE, expires_in: MAX_AGE)
      "#{mapping.topic_id}.#{signed}"
    end

    def self.verify(token)
      match = TOKEN_PATTERN.match(token.to_s)
      return unless match

      topic_id = Integer(match[1], exception: false)
      payload = verifier.verified(match[2], purpose: PURPOSE)
      return unless topic_id&.positive? && payload.is_a?(Hash)
      return unless payload["topic_id"] == topic_id

      mapping = DiscussionBridgeConnection.find_by(
        id: payload["mapping_id"],
        topic_id: topic_id,
        state: "complete",
      )
      return unless mapping
      return unless mapping.updated_at.to_i == payload["mapping_updated_at"]

      class_name = payload["class_name"].to_s
      return if class_name.split.exclude?(CommentsOnlyPresenter::CSS_CLASS)
      return unless class_name.match?(CommentsOnlyPresenter::CLASS_NAME_PATTERN)

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
