# frozen_string_literal: true

module DiscussionBridge
  class OperatorAudit
    def self.actor(user)
      prefix = user&.admin? ? "customer_admin" : "operator_user"
      "#{prefix}:#{user&.id || "system"}"
    end

    def self.record!(enrollment:, actor:, scope:, action:, target_type:, target_id:,
                     operation_sha256:, outcome:, entitlement: nil, customer_approval_id: nil)
      DiscussionBridgeOperatorAuditRecord.create!(
        event_id: "dba_#{SecureRandom.hex(16)}",
        occurred_at: Time.zone.now,
        forum_id: enrollment.forum_id,
        provider_id: enrollment.provider_id,
        entitlement_id: entitlement&.entitlement_id,
        actor: actor,
        scope: scope,
        action: action,
        target_type: target_type,
        target_id: target_id,
        operation_sha256: operation_sha256,
        customer_approval_id: customer_approval_id,
        outcome: outcome,
      )
    end
  end
end
