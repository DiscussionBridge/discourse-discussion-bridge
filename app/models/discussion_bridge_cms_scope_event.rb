# frozen_string_literal: true

class DiscussionBridgeCmsScopeEvent < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_scope_events"
  ORIGINS = %w[native_admin_scope_mutation native_model_scope_mutation].freeze
  REASONS = %w[source_scope_changed connection_disabled].freeze
  SCOPE_FIELDS = %w[enabled platform allowed_origins allowed_directions allowed_lanes].freeze
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :actor_user, class_name: "User", optional: true
  validates :event_origin, inclusion: { in: ORIGINS }
  validates :reason, inclusion: { in: REASONS }
  validates :created_at, presence: true
  validates :previous_policy_revision, :policy_revision, length: { maximum: 128 }, allow_nil: true
  validate :facts_are_closed
  before_update { throw(:abort) }
  before_destroy { throw(:abort) }

  private

  def facts_are_closed
    allowed = SCOPE_FIELDS
    valid =
      changed_fields.is_a?(Array) && changed_fields.any? && changed_fields.uniq == changed_fields &&
        (changed_fields - allowed).empty? && previous_values.is_a?(Hash) && values.is_a?(Hash) &&
        previous_values.keys.sort == changed_fields.sort && values.keys.sort == changed_fields.sort
    if valid
      valid =
        [previous_values, values].all? do |facts|
          facts.all? { |field, value| allowed_value?(field, value) }
        end
    end
    valid &&= actor_user_id.nil? if event_origin != "native_admin_scope_mutation"
    valid &&= actor_user_id.is_a?(Integer) && actor_user_id.positive? if event_origin ==
      "native_admin_scope_mutation"
    valid &&= JSON.generate([previous_values, values]).bytesize <= 262_144 if valid
    errors.add(:base, "scope event facts must be bounded native scope facts") unless valid
  end

  def allowed_value?(field, value)
    case field
    when "enabled"
      value == true || value == false
    when "platform"
      DiscussionBridgeContentConnection::PLATFORMS.include?(value)
    when "allowed_origins"
      value.is_a?(Array) && value.length <= DiscussionBridgeContentConnection::MAX_ORIGINS &&
        value.all? { |entry| entry.is_a?(String) && entry.bytesize <= 2048 }
    when "allowed_directions"
      value.is_a?(Array) && (value - DiscussionBridgeContentConnection::DIRECTIONS).empty?
    when "allowed_lanes"
      value.is_a?(Array) && value.length <= DiscussionBridgeContentConnection::MAX_LANES &&
        value.all? { |entry| entry.is_a?(String) && entry.bytesize <= 128 }
    else
      false
    end
  end
end
