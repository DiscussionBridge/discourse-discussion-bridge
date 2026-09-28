# frozen_string_literal: true

module DiscussionBridge
  class PublicationControl
    DECISIONS = %w[include exclude inherit].freeze

    def self.set!(user:, connection:, topic:, decision:)
      raise Discourse::InvalidAccess unless user&.staff?
      raise ArgumentError, "publication connection is unavailable" unless
        connection.enabled && connection.allows_direction?("from_discourse") &&
          connection.destination_policies.present?

      normalized = decision.to_s
      raise ArgumentError, "invalid publication decision" if DECISIONS.exclude?(normalized)

      record = mapped_record(connection: connection, topic: topic)
      raise ArgumentError, "topic has no authorized publication mapping" unless record

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
      SourceRevocationRegistry.reconcile_record!(record: record, connection: connection)
      override
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def self.decision(connection:, topic_id:)
      DiscussionBridgePublicationOverride.find_by(
        content_connection_id: connection.id,
        topic_id: topic_id,
      )&.decision || "inherit"
    end

    def self.excluded?(connection:, topic_id:)
      decision(connection: connection, topic_id: topic_id) == "exclude"
    end

    def self.mapped_record(connection:, topic:)
      DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(direction: "from_discourse", topic_id: topic.id)
        .where(
          discussion_bridge_content_bindings: {
            content_connection_id: connection.id,
            role: "presentation",
            state: "active",
          },
        ).distinct.first
    end
  end
end
