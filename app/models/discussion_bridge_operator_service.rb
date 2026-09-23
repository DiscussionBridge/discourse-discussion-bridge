# frozen_string_literal: true

class DiscussionBridgeOperatorService < ActiveRecord::Base
  self.table_name = "discussion_bridge_operator_services"

  GRACE_PERIOD_DAYS = 14
  SINGLETON_KEY = "current"
  STORED_STATUSES = %w[inactive pending active past_due cancelled revoked].freeze
  VIEWABLE_STATUSES = %w[active grace read_only cancelled].freeze
  MUTABLE_STATUSES = %w[active grace cancelled].freeze

  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :operator_user, class_name: "User", optional: true

  validates :installation_id, :enrollment_id, presence: true,
            format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i }
  validates :installation_id, :enrollment_id, uniqueness: true
  validates :singleton_key, inclusion: { in: [SINGLETON_KEY] }
  validates :status, inclusion: { in: STORED_STATUSES }
  validates :identity_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :entitlement_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :entitlement_digest, length: { is: 64 }, allow_nil: true
  validates :operator_email, length: { maximum: 254 }, allow_nil: true

  def self.instance
    find_or_create_by!(singleton_key: SINGLETON_KEY) do |record|
      record.installation_id = SecureRandom.uuid
      record.enrollment_id = SecureRandom.uuid
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(singleton_key: SINGLETON_KEY)
  end

  def enable!
    with_lock do
      update!(enabled: true, disabled_at: nil)
    end
  end

  def request!(user:)
    with_lock do
      raise ArgumentError, "operator service must be enabled before requesting enrollment" unless enabled?
      raise ArgumentError, "operator service enrollment has already been requested" unless request_available?

      update!(
        status: entitlement_id.present? ? status : "pending",
        requested_by: user,
        requested_at: Time.zone.now,
        disabled_at: nil,
        notification_state: "queued",
        notification_error: nil,
      )
    end
  end

  def disable!
    with_lock do
      update!(
        enabled: false,
        disabled_at: Time.zone.now,
      )
    end
  end

  def request_available?
    enabled? && entitlement_id.blank? && (requested_at.blank? || notification_state == "failed")
  end

  def apply_entitlement!(claims)
    with_lock do
      new_entitlement_version = claims.fetch("entitlement_version")
      new_identity_version = claims.fetch("identity_version")
      raise ArgumentError, "entitlement version is stale" if new_entitlement_version <= entitlement_version
      raise ArgumentError, "entitlement identity version is stale" if new_identity_version < identity_version
      identity_changed = operator_identity_id.present? && (
        claims.fetch("operator_identity_id") != operator_identity_id ||
          !claims.fetch("operator_email").casecmp?(operator_email.to_s)
      )
      raise ArgumentError, "operator identity change requires a newer identity version" if
        identity_changed && new_identity_version <= identity_version

      update!(
        status: claims.fetch("status"),
        entitlement_id: claims.fetch("entitlement_id"),
        operator_identity_id: claims.fetch("operator_identity_id"),
        operator_email: claims.fetch("operator_email"),
        identity_version: new_identity_version,
        entitlement_version: new_entitlement_version,
        plan_id: claims.fetch("plan_id"),
        issued_at: claims.fetch("issued_at"),
        paid_through_at: claims.fetch("paid_through_at"),
        grace_expires_at: claims.fetch("grace_expires_at"),
        entitlement_digest: claims.fetch("entitlement_digest"),
        entitlement_payload: claims.except("entitlement_digest"),
      )
      reconcile_operator_user!
    end
  end

  def reconcile_operator_user!
    candidate = operator_email.present? ? User.find_by_email(operator_email) : nil
    candidate = nil unless self.class.eligible_operator_user?(candidate)
    update_column(:operator_user_id, candidate&.id) if operator_user_id != candidate&.id
    candidate
  end

  def effective_status(now: Time.zone.now)
    return "inactive" unless enabled
    return "pending" if entitlement_id.blank?
    return "revoked" if status == "revoked"
    return "read_only" unless paid_through_at && grace_expires_at
    return status == "cancelled" ? "cancelled" : "active" if now <= paid_through_at
    return "read_only" if status == "cancelled"
    return "grace" if status == "past_due" && now <= grace_expires_at

    "read_only"
  end

  def view_allowed?(user, now: Time.zone.now)
    return true if user&.admin?
    VIEWABLE_STATUSES.include?(effective_status(now: now)) && operator_matches?(user)
  end

  def mutation_allowed?(user, now: Time.zone.now)
    return true if user&.admin?
    MUTABLE_STATUSES.include?(effective_status(now: now)) && operator_matches?(user)
  end

  def operator_matches?(user)
    self.class.eligible_operator_user?(user) && operator_user_id.present? && user.id == operator_user_id
  end

  def self.eligible_operator_user?(user)
    user.present? && user.active? && !user.staged? && user.id != Discourse::SYSTEM_USER_ID &&
      !user.suspended? && !user.silenced?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_operator_services
#
#  id                   :bigint           not null, primary key
#  disabled_at          :datetime
#  enabled              :boolean          default(FALSE), not null
#  entitlement_digest   :string(64)
#  entitlement_payload  :jsonb            not null
#  entitlement_version  :integer          default(0), not null
#  grace_expires_at     :datetime
#  identity_version     :integer          default(0), not null
#  issued_at            :datetime
#  notification_error   :text
#  notification_sent_at :datetime
#  notification_state   :string(32)       default("not_sent"), not null
#  operator_email       :string(254)
#  paid_through_at      :datetime
#  requested_at         :datetime
#  singleton_key        :string(16)       default("current"), not null
#  status               :string(32)       default("inactive"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  enrollment_id        :string(36)       not null
#  entitlement_id       :string(64)
#  installation_id      :string(36)       not null
#  operator_identity_id :string(100)
#  operator_user_id     :bigint
#  plan_id              :string(100)
#  requested_by_id      :bigint
#
# Indexes
#
#  idx_discussion_bridge_operator_service_enrollment              (enrollment_id) UNIQUE
#  idx_discussion_bridge_operator_service_entitlement             (entitlement_id) UNIQUE WHERE (entitlement_id IS NOT NULL)
#  idx_discussion_bridge_operator_service_installation            (installation_id) UNIQUE
#  idx_discussion_bridge_operator_service_singleton               (singleton_key) UNIQUE
#  index_discussion_bridge_operator_services_on_operator_user_id  (operator_user_id)
#
