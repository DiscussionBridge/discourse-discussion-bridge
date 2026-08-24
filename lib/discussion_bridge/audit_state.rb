# frozen_string_literal: true

require "json"

module DiscussionBridge
  module AuditState
    REQUESTED_KEYS = %w[actor category_id tags visibility lane adapter_id].freeze
    EFFECTIVE_KEYS = %w[actor_id category_id tags visibility policy].freeze
    MAX_JSON_BYTES = 64 * 1024
    MAX_ARRAY_LENGTH = 20
    MAX_STRING_BYTES = 2048
    CONTROL_PATTERN = /[\x00-\x1f\x7f]/

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
        JSON.generate(payload).bytesize <= MAX_JSON_BYTES &&
        payload.values.all? { |value| scalar_or_scalar_array?(value) }
    rescue JSON::GeneratorError
      false
    end

    def self.scalar_or_scalar_array?(value)
      value.nil? || valid_string?(value) || value.is_a?(Integer) || value == true || value == false ||
        (value.is_a?(Array) && value.length <= MAX_ARRAY_LENGTH &&
          value.all? { |entry| valid_string?(entry) || entry.is_a?(Integer) })
    end
    private_class_method :scalar_or_scalar_array?

    def self.valid_string?(value)
      value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_STRING_BYTES &&
        !CONTROL_PATTERN.match?(value)
    end
    private_class_method :valid_string?
  end
end
