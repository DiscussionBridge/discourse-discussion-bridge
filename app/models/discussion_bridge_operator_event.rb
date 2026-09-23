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

# == Schema Information
#
# Table name: discussion_bridge_operator_events
#
#  id                    :bigint           not null, primary key
#  details               :jsonb            not null
#  event_type            :string(100)      not null
#  outcome               :string(32)       not null
#  created_at            :datetime         not null
#  actor_user_id         :bigint
#  bridge_record_id      :bigint
#  content_connection_id :bigint
#  operator_service_id   :bigint           not null
#  topic_id              :bigint
#
# Indexes
#
#  idx_discussion_bridge_operator_events_connection                (content_connection_id)
#  idx_discussion_bridge_operator_events_record                    (bridge_record_id)
#  index_discussion_bridge_operator_events_on_actor_user_id        (actor_user_id)
#  index_discussion_bridge_operator_events_on_created_at           (created_at)
#  index_discussion_bridge_operator_events_on_operator_service_id  (operator_service_id)
#  index_discussion_bridge_operator_events_on_topic_id             (topic_id)
#
# Foreign Keys
#
#  fk_rails_...  (operator_service_id => discussion_bridge_operator_services.id)
#
