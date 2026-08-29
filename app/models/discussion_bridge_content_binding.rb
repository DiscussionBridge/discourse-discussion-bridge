# frozen_string_literal: true

class DiscussionBridgeContentBinding < ActiveRecord::Base
  self.table_name = "discussion_bridge_content_bindings"

  ROLES = %w[source presentation].freeze
  STATES = %w[prepared active historical].freeze

  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"

  validates :role, inclusion: { in: ROLES }
  validates :state, inclusion: { in: STATES }
  validates :external_id, :canonical_url, :identity_digest, :canonical_url_digest, presence: true
  validates :external_id, length: { maximum: 255 }
  validates :canonical_url, length: { maximum: DiscussionBridge::CanonicalSource::MAX_SOURCE_URL_LENGTH }
  validates :identity_digest, length: { is: 64 }, uniqueness: true
  validates :canonical_url_digest, length: { is: 64 }, uniqueness: true
  validates :external_id, uniqueness: { scope: :content_connection_id }
  validate :one_current_binding_per_role
  validate :external_id_is_safe

  def self.valid_external_id?(value)
    value.is_a?(String) && value.valid_encoding? && value.present? &&
      value == value.strip && value.bytesize <= 255 && !value.match?(/[\x00-\x1f\x7f]/)
  end

  private

  def external_id_is_safe
    errors.add(:external_id, "is invalid") unless self.class.valid_external_id?(external_id)
  end

  def one_current_binding_per_role
    return if %w[active prepared].exclude?(state)

    scope = self.class.where(bridge_record_id: bridge_record_id, role: role, state: state)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:state, "already exists for this record and role") if scope.exists?
  end
end
