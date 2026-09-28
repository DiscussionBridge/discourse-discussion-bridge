# frozen_string_literal: true

module DiscussionBridge
  class OperatorServiceAccess
    APPLY_SCOPES = %w[
      apply_customer_approved_reconciliation apply_customer_approved_connection_change
      apply_customer_approved_upgrade
    ].freeze

    def self.authorize!(user:, scope:, operation_sha256:, customer_approval_id: nil, at: Time.zone.now)
      denied!("scope_denied") unless operation_sha256.to_s.match?(/\A[a-f0-9]{64}\z/)
      enrollment = DiscussionBridgeOperatorEnrollment.instance
      entitlement = enrollment.current_entitlement
      denied!("scope_denied") unless enrollment.enabled? && entitlement
      denied!("scope_denied") unless DiscussionBridgeOperatorEnrollment.eligible_operator_user?(user)
      denied!("scope_denied") unless enrollment.operator_user_id == user&.id

      state = entitlement.effective_state(at: at)
      denied!("entitlement_revoked") if state == "revoked"
      denied!("entitlement_replaced") if state == "replaced"
      denied!("entitlement_expired") if state == "expired"
      denied!("scope_denied") unless entitlement.scope_allowed?(scope, at: at)

      DiscussionBridgeOperatorAuditRecord.transaction do
        approval = nil
        if APPLY_SCOPES.include?(scope)
          approval = DiscussionBridgeOperatorApproval.lock.find_by(approval_id: customer_approval_id)
          denied!("scope_denied") unless approval&.usable_for?(
            enrollment: enrollment,
            entitlement: entitlement,
            requested_scope: scope,
            requested_operation_sha256: operation_sha256,
            at: at,
          )
          approval.update!(consumed_at: at)
        end

        DiscussionBridge::OperatorAudit.record!(
          enrollment: enrollment,
          entitlement: entitlement,
          actor: DiscussionBridge::OperatorAudit.actor(user),
          scope: scope,
          action: "authorize_operation",
          target_type: "operation",
          target_id: operation_sha256,
          operation_sha256: operation_sha256,
          customer_approval_id: approval&.approval_id,
          outcome: "applied",
        )
      end
      true
    end

    def self.denied!(code)
      raise DiscussionBridge::OperatorEntitlementVerifier::VerificationError, code
    end
    private_class_method :denied!
  end
end
