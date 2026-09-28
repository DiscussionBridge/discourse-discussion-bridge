# frozen_string_literal: true

class DiscussionBridgeOperatorEnrollment < ActiveRecord::Base
  self.table_name = "discussion_bridge_operator_enrollments"

  SINGLETON_KEY = "current"
  STATES = DiscussionBridge::OperatorServiceContract::STATES

  belongs_to :operator_user, class_name: "User", optional: true

  validates :singleton_key, inclusion: { in: [SINGLETON_KEY] }
  validates :forum_id, format: { with: /\Adbf_[a-f0-9]{32}\z/ }, uniqueness: true
  validates :provider_id, format: { with: /\Adbp_[a-f0-9]{32}\z/ }
  validates :provider_name, presence: true, length: { maximum: 200 }
  validates :state, inclusion: { in: STATES }

  def self.instance
    find_or_create_by!(singleton_key: SINGLETON_KEY) do |record|
      provider = DiscussionBridge::OperatorProviderRegistry.fetch(
        DiscussionBridge::OperatorProviderRegistry::DISCUSSIONBRIDGE_PROVIDER_ID,
      )
      record.forum_id = "dbf_#{SecureRandom.hex(16)}"
      record.provider_id = provider.fetch(:id)
      record.provider_name = provider.fetch(:name)
      record.state = "pending_enrollment"
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(singleton_key: SINGLETON_KEY)
  end

  def current_entitlement
    return nil if current_entitlement_id.blank?

    DiscussionBridgeOperatorEntitlement.find_by(entitlement_id: current_entitlement_id)
  end

  def effective_state(at: Time.zone.now)
    entitlement = current_entitlement
    return "pending_enrollment" unless enabled? && entitlement

    entitlement.effective_state(at: at)
  end

  def enable!
    next_state = current_entitlement&.effective_state || "pending_enrollment"
    update!(enabled: true, disabled_at: nil, state: next_state)
  end

  def disable!
    update!(enabled: false, disabled_at: Time.zone.now)
  end

  def bind_operator_user!(user)
    raise ArgumentError, "operator user must be active and non-system" unless self.class.eligible_operator_user?(user)

    update!(operator_user: user)
  end

  def activate!(entitlement:, actor:)
    with_lock do
      raise ArgumentError, "operator service is disabled" unless enabled?
      raise ArgumentError, "entitlement provider does not match enrollment" unless entitlement.provider_id == provider_id
      raise ArgumentError, "entitlement forum does not match enrollment" unless entitlement.forum_id == forum_id

      previous = current_entitlement
      if previous && previous.id != entitlement.id && !%w[revoked replaced].include?(previous.state)
        previous.update!(state: "replaced", replaced_by_entitlement_id: entitlement.entitlement_id)
      end
      entitlement.update!(state: entitlement.effective_state)
      update!(current_entitlement_id: entitlement.entitlement_id, state: entitlement.effective_state)

      DiscussionBridge::OperatorAudit.record!(
        enrollment: self,
        entitlement: entitlement,
        actor: DiscussionBridge::OperatorAudit.actor(actor),
        scope: "provider_enrollment",
        action: "enroll_entitlement",
        target_type: "operator_entitlement",
        target_id: entitlement.entitlement_id,
        operation_sha256: entitlement.payload_sha256,
        customer_approval_id: "enrollment:#{entitlement.entitlement_id}",
        outcome: "approved",
      )
    end
  end

  def revoke_current!(actor:)
    with_lock do
      entitlement = current_entitlement
      raise ArgumentError, "operator entitlement is unavailable" unless entitlement

      entitlement.update!(state: "revoked", revoked_at: Time.zone.now)
      update!(state: "revoked")
      DiscussionBridge::OperatorAudit.record!(
        enrollment: self,
        entitlement: entitlement,
        actor: DiscussionBridge::OperatorAudit.actor(actor),
        scope: "provider_enrollment",
        action: "revoke_entitlement",
        target_type: "operator_entitlement",
        target_id: entitlement.entitlement_id,
        operation_sha256: entitlement.payload_sha256,
        customer_approval_id: "revocation:#{entitlement.entitlement_id}",
        outcome: "revoked",
      )
    end
  end

  def self.eligible_operator_user?(user)
    user.present? && user.active? && !user.staged? && !user.suspended? &&
      !user.silenced? && user.id != Discourse::SYSTEM_USER_ID
  end
end

# == Schema Information
#
# Table name: discussion_bridge_operator_enrollments
#
#  id                     :bigint           not null, primary key
#  disabled_at            :datetime
#  enabled                :boolean          default(FALSE), not null
#  provider_name          :string(200)      not null
#  singleton_key          :string(16)       default("current"), not null
#  state                  :string(32)       default("pending_enrollment"), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  current_entitlement_id :string(36)
#  forum_id               :string(36)       not null
#  operator_user_id       :bigint
#  provider_id            :string(36)       not null
#
# Indexes
#
#  idx_db_operator_enrollment_forum      (forum_id) UNIQUE
#  idx_db_operator_enrollment_singleton  (singleton_key) UNIQUE
#  idx_db_operator_enrollment_user       (operator_user_id)
#
