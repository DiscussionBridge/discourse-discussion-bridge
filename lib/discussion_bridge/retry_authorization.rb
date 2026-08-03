# frozen_string_literal: true

module DiscussionBridge
  class RetryAuthorization
    Result = Data.define(:authorized, :reason, :mapping)

    def self.call(mapping_id:, administrator:, now: Time.zone.now)
      mapping = nil
      result = nil
      DiscussionBridgeConnection.transaction do
        mapping = DiscussionBridgeConnection.lock.find(mapping_id)
        if eligible?(mapping, now)
          mapping.update!(
            retry_authorized_at: now,
            retry_authorized_by_id: administrator.id,
          )
          write_audit(mapping, administrator)
          result = Result.new(authorized: true, reason: "retry_authorized", mapping: mapping)
        else
          result = Result.new(authorized: false, reason: "retry_not_eligible", mapping: mapping)
        end
      end
      result
    end

    def self.revoke(mapping_id:, administrator:)
      mapping = nil
      result = nil
      DiscussionBridgeConnection.transaction do
        mapping = DiscussionBridgeConnection.lock.find(mapping_id)
        if mapping.retry_authorized_at.present?
          mapping.update!(retry_authorized_at: nil, retry_authorized_by_id: nil)
          write_audit(
            mapping,
            administrator,
            outcome: "reconciliation_revoked",
            reason: "retry_authorization_revoked",
            policy: "operator_retry_authorization_revoked",
          )
          result = Result.new(authorized: false, reason: "retry_authorization_revoked", mapping: mapping)
        else
          result = Result.new(authorized: false, reason: "retry_not_authorized", mapping: mapping)
        end
      end
      result
    end

    def self.eligible?(mapping, now)
      return false if mapping.retry_authorized_at.present?

      mapping.state == "failed" ||
        (mapping.state == "reserved" && mapping.updated_at <= now - ReconciliationIndex::STALE_RESERVATION_AGE)
    end
    private_class_method :eligible?

    def self.write_audit(
      mapping,
      administrator,
      outcome: "reconciliation_authorized",
      reason: "retry_authorized",
      policy: "operator_retry_authorization"
    )
      DiscussionBridgeAuditEvent.create!(
        connection_id: mapping.connection_id,
        source_identity_digest: mapping.source_identity_digest,
        topic_id: mapping.topic_id,
        effective_actor_id: administrator.id,
        outcome: outcome,
        reason: reason,
        requested_state: {},
        effective_state: {
          "actor_id" => administrator.id,
          "policy" => policy,
        },
      )
    end
    private_class_method :write_audit
  end
end
