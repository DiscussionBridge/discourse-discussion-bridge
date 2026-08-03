# frozen_string_literal: true

class DiscussionBridgeConnection < ActiveRecord::Base
  class IdentityConflict < StandardError; end

  self.table_name = "discussion_bridge_connections"

  belongs_to :topic, optional: true
  belongs_to :effective_actor, class_name: "User", optional: true
  belongs_to :retry_authorized_by, class_name: "User", optional: true

  STATES = %w[reserved complete failed].freeze

  validates :connection_id, :canonical_source_url, :source_identity_digest, :state, presence: true
  validates :source_identity_digest, length: { is: 64 }, uniqueness: true
  validates :state, inclusion: { in: STATES }
  validates :reservation_token, length: { is: 64 }, allow_nil: true
  validates :topic_id, uniqueness: true, allow_nil: true
  validate :audit_state_is_allowlisted
  validate :reservation_state_is_consistent

  private

  def audit_state_is_allowlisted
    unless DiscussionBridge::AuditState.valid?(requested_state, DiscussionBridge::AuditState::REQUESTED_KEYS)
      errors.add(:requested_state, "contains unsupported fields or values")
    end
    unless DiscussionBridge::AuditState.valid?(effective_state, DiscussionBridge::AuditState::EFFECTIVE_KEYS)
      errors.add(:effective_state, "contains unsupported fields or values")
    end
  end

  def reservation_state_is_consistent
    if state == "reserved" && reservation_token.blank?
      errors.add(:reservation_token, "is required while reserved")
    elsif state != "reserved" && reservation_token.present?
      errors.add(:reservation_token, "must be cleared after reservation")
    end
  end
end
