# frozen_string_literal: true

module DiscussionBridge
  class OperatorAudit
    def self.record(event_type:, actor: nil, outcome: "completed", topic: nil, connection: nil,
                    bridge_record: nil, details: {})
      DiscussionBridgeOperatorEvent.create!(
        operator_service: DiscussionBridgeOperatorService.instance,
        actor_user: actor,
        topic: topic,
        content_connection: connection,
        bridge_record: bridge_record,
        event_type: event_type,
        outcome: outcome,
        details: details.compact.stringify_keys,
        created_at: Time.zone.now,
      )
    end
  end
end
