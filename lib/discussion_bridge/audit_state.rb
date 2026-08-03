# frozen_string_literal: true

module DiscussionBridge
  module AuditState
    REQUESTED_KEYS = %w[actor category_id tags visibility lane adapter_id].freeze
    EFFECTIVE_KEYS = %w[actor_id category_id tags visibility policy].freeze

    def self.requested(request)
      {
        "actor" => request[:actor]&.to_s,
        "category_id" => request[:category_id],
        "tags" => Array(request[:tags]).map(&:to_s),
        "visibility" => request[:visibility]&.to_s,
        "lane" => request[:lane]&.to_s,
        "adapter_id" => request[:adapter_id]&.to_s,
      }.compact
    end

    def self.effective(policy)
      {
        "actor_id" => policy.effective_actor_id,
        "category_id" => policy.respond_to?(:effective_category_id) ? policy.effective_category_id : nil,
        "tags" => policy.respond_to?(:effective_tags) ? Array(policy.effective_tags).map(&:to_s) : [],
        "visibility" => policy.effective_visibility,
        "policy" => policy.reason,
      }.compact
    end

    def self.valid?(payload, allowed_keys)
      payload.is_a?(Hash) && payload.keys.map(&:to_s).all? { |key| allowed_keys.include?(key) } &&
        payload.values.all? { |value| scalar_or_scalar_array?(value) }
    end

    def self.scalar_or_scalar_array?(value)
      value.nil? || value.is_a?(String) || value.is_a?(Integer) || value == true || value == false ||
        (value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) || entry.is_a?(Integer) })
    end
    private_class_method :scalar_or_scalar_array?
  end
end
