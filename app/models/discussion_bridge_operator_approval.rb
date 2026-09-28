# frozen_string_literal: true

class DiscussionBridgeOperatorApproval < ActiveRecord::Base
  self.table_name = "discussion_bridge_operator_approvals"

  belongs_to :approved_by, class_name: "User"

  validates :approval_id, :forum_id, :provider_id, :entitlement_id, :scope, presence: true
  validates :approval_id, uniqueness: true, length: { maximum: 200 }
  validates :operation_sha256, format: { with: /\A[a-f0-9]{64}\z/ }
  validates :scope, inclusion: { in: DiscussionBridge::OperatorServiceAccess::APPLY_SCOPES }
  validate :expires_in_the_future

  def usable_for?(enrollment:, entitlement:, requested_scope:, requested_operation_sha256:, at: Time.zone.now)
    consumed_at.nil? && at < expires_at && forum_id == enrollment.forum_id &&
      provider_id == enrollment.provider_id && entitlement_id == entitlement.entitlement_id &&
      scope == requested_scope && operation_sha256 == requested_operation_sha256
  end

  private

  def expires_in_the_future
    errors.add(:expires_at, "must be in the future") if expires_at && expires_at <= Time.zone.now
  end
end

# == Schema Information
#
# Table name: discussion_bridge_operator_approvals
#
#  id               :bigint           not null, primary key
#  consumed_at      :datetime
#  expires_at       :datetime         not null
#  operation_sha256 :string(64)       not null
#  scope            :string(80)       not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  approval_id      :string(200)      not null
#  approved_by_id   :bigint           not null
#  entitlement_id   :string(36)       not null
#  forum_id         :string(36)       not null
#  provider_id      :string(36)       not null
#
# Indexes
#
#  idx_db_operator_approvals_binding   (forum_id,provider_id,entitlement_id,scope,operation_sha256)
#  idx_db_operator_approvals_identity  (approval_id) UNIQUE
#
