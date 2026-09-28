# frozen_string_literal: true

class DiscussionBridgeOperatorEntitlement < ActiveRecord::Base
  self.table_name = "discussion_bridge_operator_entitlements"

  STATES = %w[active grace_read_only expired revoked replaced].freeze
  OBSERVATION_SCOPES = %w[observe_health observe_publication].freeze

  belongs_to :enrolled_by, class_name: "User"

  validates :entitlement_id, format: { with: /\Adbe_[a-f0-9]{32}\z/ }, uniqueness: true
  validates :provider_id, :forum_id, :issuer_id, presence: true
  validates :state, inclusion: { in: STATES }
  validates :payload_sha256, format: { with: /\A[a-f0-9]{64}\z/ }
  validates :entitlement_version, numericality: { only_integer: true, equal_to: 1 }

  def effective_state(at: Time.zone.now)
    return state if %w[revoked replaced].include?(state)
    return "expired" if at > grace_until
    return "grace_read_only" if at > expires_at

    "active"
  end

  def scope_allowed?(scope, at: Time.zone.now)
    return false if scopes.exclude?(scope)

    current = effective_state(at: at)
    current == "active" || (current == "grace_read_only" && OBSERVATION_SCOPES.include?(scope))
  end
end

# == Schema Information
#
# Table name: discussion_bridge_operator_entitlements
#
#  id                         :bigint           not null, primary key
#  activated_at               :datetime         not null
#  entitlement_version        :integer          not null
#  expires_at                 :datetime         not null
#  grace_until                :datetime         not null
#  issued_at                  :datetime         not null
#  not_before                 :datetime         not null
#  payload                    :jsonb            not null
#  payload_sha256             :string(64)       not null
#  provider_name              :string(200)      not null
#  revoked_at                 :datetime
#  scopes                     :jsonb            not null
#  signature                  :string(100)      not null
#  state                      :string(32)       not null
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  enrolled_by_id             :bigint           not null
#  entitlement_id             :string(36)       not null
#  forum_id                   :string(36)       not null
#  issuer_id                  :string(36)       not null
#  key_id                     :string(200)      not null
#  provider_id                :string(36)       not null
#  replaced_by_entitlement_id :string(36)
#
# Indexes
#
#  idx_db_operator_entitlements_forum_state  (forum_id,state)
#  idx_db_operator_entitlements_identity     (entitlement_id) UNIQUE
#  idx_db_operator_entitlements_key          (issuer_id,key_id)
#
