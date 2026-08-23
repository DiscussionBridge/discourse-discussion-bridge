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

# == Schema Information
#
# Table name: discussion_bridge_audit_events
#
#  id                     :bigint           not null, primary key
#  effective_state        :jsonb            not null
#  outcome                :string           not null
#  reason                 :string           not null
#  requested_state        :jsonb            not null
#  source_identity_digest :string(64)       not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  adapter_id             :string
#  connection_id          :string           not null
#  correlation_id         :string
#  effective_actor_id     :bigint
#  topic_id               :bigint
#
# Indexes
#
#  idx_discussion_bridge_audits_source                     (source_identity_digest)
#  index_discussion_bridge_audit_events_on_correlation_id  (correlation_id)
#  index_discussion_bridge_audit_events_on_created_at      (created_at)
#  index_discussion_bridge_audit_events_on_topic_id        (topic_id)
#
