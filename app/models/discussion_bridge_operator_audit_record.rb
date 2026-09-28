# frozen_string_literal: true

class DiscussionBridgeOperatorAuditRecord < ActiveRecord::Base
  self.table_name = "discussion_bridge_operator_audit_records"

  OUTCOMES = DiscussionBridge::OperatorServiceContract::AUDIT_OUTCOMES
  CONTRACT_FIELDS = DiscussionBridge::OperatorServiceContract::AUDIT_FIELDS

  validates :event_id, format: { with: /\Adba_[a-f0-9]{32}\z/ }, uniqueness: true
  validates :forum_id, :provider_id, :actor, :scope, :action, :target_type, :target_id, presence: true
  validates :operation_sha256, format: { with: /\A[a-f0-9]{64}\z/ }
  validates :outcome, inclusion: { in: OUTCOMES }

  def contract_payload
    {
      event_id: event_id,
      occurred_at: occurred_at.utc.iso8601(6),
      forum_id: forum_id,
      provider_id: provider_id,
      entitlement_id: entitlement_id,
      actor: actor,
      scope: scope,
      action: action,
      target_type: target_type,
      target_id: target_id,
      operation_sha256: operation_sha256,
      customer_approval_id: customer_approval_id,
      outcome: outcome,
    }
  end
end

# == Schema Information
#
# Table name: discussion_bridge_operator_audit_records
#
#  id                   :bigint           not null, primary key
#  action               :string(100)      not null
#  actor                :string(200)      not null
#  occurred_at          :datetime         not null
#  operation_sha256     :string(64)       not null
#  outcome              :string(32)       not null
#  scope                :string(80)       not null
#  target_type          :string(100)      not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  customer_approval_id :string(200)
#  entitlement_id       :string(36)
#  event_id             :string(36)       not null
#  forum_id             :string(36)       not null
#  provider_id          :string(36)       not null
#  target_id            :string(200)      not null
#
# Indexes
#
#  idx_db_operator_audit_entitlement  (entitlement_id)
#  idx_db_operator_audit_event        (event_id) UNIQUE
#  idx_db_operator_audit_forum_time   (forum_id,occurred_at)
#
