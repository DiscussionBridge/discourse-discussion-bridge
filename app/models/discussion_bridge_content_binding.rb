# frozen_string_literal: true

class DiscussionBridgeContentBinding < ActiveRecord::Base
  self.table_name = "discussion_bridge_content_bindings"

  ROLES = %w[source presentation].freeze
  STATES = %w[prepared active historical].freeze
  PRESENTATION_MODES = %w[simple full interactive].freeze

  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_connection,
             class_name: "DiscussionBridgeContentConnection"

  validates :role, inclusion: { in: ROLES }
  validates :cms_protocol_version, inclusion: { in: [1, 2] }
  validates :state, inclusion: { in: STATES }
  validates :presentation_mode,
            inclusion: {
              in: PRESENTATION_MODES
            },
            allow_nil: true
  validates :external_id,
            :canonical_url,
            :identity_digest,
            :canonical_url_digest,
            presence: true
  validates :external_id, length: { maximum: 255 }
  validates :canonical_url,
            length: {
              maximum: DiscussionBridge::CanonicalSource::MAX_SOURCE_URL_LENGTH
            }
  validates :identity_digest, length: { is: 64 }, uniqueness: true
  validates :canonical_url_digest, length: { is: 64 }, uniqueness: true
  validates :external_id, uniqueness: { scope: :content_connection_id }
  validate :one_current_binding_per_role
  validate :external_id_is_safe

  def self.valid_external_id?(value)
    value.is_a?(String) && value.valid_encoding? && value.present? &&
      value == value.strip && value.bytesize <= 255 &&
      !value.match?(/[\x00-\x1f\x7f]/)
  end

  private

  def external_id_is_safe
    if cms_protocol_version == 2
      DiscussionBridge::CmsProtocol.validate!("OpaqueId", external_id)
      DiscussionBridge::CmsProtocol.validate!("Url", canonical_url)
    else
      unless self.class.valid_external_id?(external_id)
        errors.add(:external_id, "is invalid")
      end
    end
  rescue DiscussionBridge::CmsProtocol::Error
    errors.add(:external_id, "or canonical URL is invalid")
  end

  def one_current_binding_per_role
    return if %w[active prepared].exclude?(state)

    scope =
      self.class.where(
        bridge_record_id: bridge_record_id,
        role: role,
        state: state
      )
    scope = scope.where.not(id: id) if persisted?
    if scope.exists?
      errors.add(:state, "already exists for this record and role")
    end
  end
end

# == Schema Information
#
# Table name: discussion_bridge_content_bindings
#
#  id                     :bigint           not null, primary key
#  activated_at           :datetime
#  canonical_url          :text             not null
#  canonical_url_digest   :string(64)       not null
#  identity_digest        :string(64)       not null
#  native_materialization :boolean          default(FALSE), not null
#  retired_at             :datetime
#  role                   :string(32)       not null
#  state                  :string(32)       default("active"), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  bridge_record_id       :bigint           not null
#  content_connection_id  :bigint           not null
#  external_id            :string(255)      not null
#
# Indexes
#
#  idx_db_bindings_bridge_record                       (bridge_record_id)
#  idx_db_bindings_content_connection                  (content_connection_id)
#  idx_db_bindings_identity                            (identity_digest) UNIQUE
#  idx_discussion_bridge_bindings_canonical_url        (canonical_url_digest) UNIQUE
#  idx_discussion_bridge_bindings_connection_external  (content_connection_id,external_id) UNIQUE
#  idx_discussion_bridge_bindings_one_active           (bridge_record_id,role) UNIQUE WHERE ((state)::text = 'active'::text)
#  idx_discussion_bridge_bindings_one_prepared         (bridge_record_id,role) UNIQUE WHERE ((state)::text = 'prepared'::text)
#  idx_discussion_bridge_bindings_record_role_state    (bridge_record_id,role,state)
#
