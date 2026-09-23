# frozen_string_literal: true

module DiscussionBridge
  class PublicationOverrideManager
    DECISIONS = (DiscussionBridgePublicationOverride::DECISIONS + ["inherit"]).freeze

    def self.call(user:, connection:, topic:, decision:)
      raise Discourse::InvalidAccess unless DiscussionBridge::OperatorServiceAccess.mutate?(user)
      raise ArgumentError, "publication connection is unavailable" unless
        PublicationWorkQueue.publication_connection?(connection)

      normalized = decision.to_s
      raise ArgumentError, "invalid publication decision" if DECISIONS.exclude?(normalized)

      if normalized == "publish"
        hard_eligibility = PublicationTopicScope.hard_eligibility(connection, topic)
        unless hard_eligibility.fetch(:eligible)
          raise ArgumentError, "topic cannot be published: #{hard_eligibility.fetch(:reason)}"
        end
      end

      override = nil
      DiscussionBridgePublicationOverride.transaction do
        override = DiscussionBridgePublicationOverride.lock.find_by(
          content_connection_id: connection.id,
          topic_id: topic.id,
        )
        if normalized == "inherit"
          override&.destroy!
          override = nil
        elsif override
          override.update!(decision: normalized, set_by: user)
        else
          override = DiscussionBridgePublicationOverride.create!(
            content_connection: connection,
            topic: topic,
            set_by: user,
            decision: normalized,
          )
        end
      end

      PublicationWorkQueue.reconcile_topic!(topic_id: topic.id, connection: connection)
      override
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
