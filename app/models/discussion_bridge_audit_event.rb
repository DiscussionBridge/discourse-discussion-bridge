# frozen_string_literal: true

class DiscussionBridgeAuditEvent < ActiveRecord::Base
  self.table_name = "discussion_bridge_audit_events"

  belongs_to :topic, optional: true
  belongs_to :effective_actor, class_name: "User", optional: true

  validates :connection_id, :source_identity_digest, :outcome, :reason, presence: true
  validates :source_identity_digest, length: { is: 64 }
  validate :payload_is_allowlisted

  private

  def payload_is_allowlisted
    unless DiscussionBridge::AuditState.valid?(requested_state, DiscussionBridge::AuditState::REQUESTED_KEYS)
      errors.add(:requested_state, "contains unsupported fields or values")
    end
    unless DiscussionBridge::AuditState.valid?(effective_state, DiscussionBridge::AuditState::EFFECTIVE_KEYS)
      errors.add(:effective_state, "contains unsupported fields or values")
    end
  end
end
