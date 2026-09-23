# frozen_string_literal: true

class DiscussionBridgeOperatorEvent < ActiveRecord::Base
  self.table_name = "discussion_bridge_operator_events"

  DETAIL_KEYS = %w[
    action decision entitlement_id entitlement_version identity_version operator_identity_id
    previous_identity_id resource_id status
  ].freeze

  belongs_to :operator_service, class_name: "DiscussionBridgeOperatorService"
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :topic, optional: true
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection", optional: true
  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord", optional: true

  validates :event_type, :outcome, presence: true
  validates :event_type, length: { maximum: 100 }
  validates :outcome, length: { maximum: 32 }
  validate :details_are_bounded

  private

  def details_are_bounded
    valid = details.is_a?(Hash) && details.keys.all? { |key| DETAIL_KEYS.include?(key.to_s) } &&
      details.values.all? { |value| value.nil? || value == true || value == false || value.is_a?(Integer) ||
        (value.is_a?(String) && value.valid_encoding? && value.bytesize <= 500 && !value.match?(/[\x00-\x1f\x7f]/)) }
    errors.add(:details, "contains unsupported fields or values") unless valid
  end
end
