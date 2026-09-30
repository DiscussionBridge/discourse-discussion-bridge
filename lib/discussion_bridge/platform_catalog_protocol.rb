# frozen_string_literal: true

module DiscussionBridge
  module PlatformCatalogProtocol
    QUERY_FIELDS = %w[platform_profile segment_type cursor limit catalog_revision].freeze
    RESPONSE_FIELDS = %w[
      catalog_revision
      platform_profile
      segment_type
      items
      next_cursor
      complete
      correlation_id
    ].freeze
    UPDATE_REQUIRED_FIELDS = %w[platform_profile base_catalog_revision segments correlation_id].freeze
    UPDATE_RESPONSE_FIELDS = %w[catalog_revision platform_profile accepted_segments correlation_id].freeze
    SEGMENT_FIELDS = %w[segment_type items].freeze
    SEGMENT_TYPES = %w[
      containers
      taxonomies
      terms
      authors
      presentation_modes
      native_limits
    ].freeze
    ITEM_SCHEMAS = {
      "containers" => %w[id name kind available],
      "taxonomies" => %w[id name hierarchical available],
      "terms" => %w[id taxonomy_id name parent_id available],
      "authors" => %w[id name available],
      "presentation_modes" => %w[id name available],
      "native_limits" => %w[id name maximum_bytes overflow_behavior available],
    }.freeze
    OVERFLOW_BEHAVIORS = %w[complete excerpt_with_read_more operator_attention].freeze
    MAXIMUM_JSON_BYTES = 65_536
    MAXIMUM_ITEMS = 100
    DEFAULT_LIMIT = 100
    MAXIMUM_CURSOR_BYTES = 8_192
    CONTROL_PATTERN = /[\x00-\x1f\x7f]/

    def self.validate_segment!(segment)
      value = stringify(segment)
      exact_keys!(value, SEGMENT_FIELDS)
      type = value["segment_type"]
      raise AdapterRequestBoundary::Error, "validation_failed" if SEGMENT_TYPES.exclude?(type)

      validate_items!(type, value["items"])
      value
    end

    def self.validate_items!(segment_type, items)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        items.is_a?(Array) && items.length <= MAXIMUM_ITEMS

      schema = ITEM_SCHEMAS.fetch(segment_type)
      identifiers = items.map do |item|
        value = stringify(item)
        exact_keys!(value, schema)
        validate_item!(segment_type, value)
        value.fetch("id")
      end
      raise AdapterRequestBoundary::Error, "validation_failed" unless identifiers.uniq.length == identifiers.length

      true
    end

    def self.validate_profile!(connection, profile)
      raise AdapterRequestBoundary::Error, "policy_denied" unless
        connection.enabled && connection.allows_direction?("from_discourse") &&
          ConnectionCapability.profiles_within_connection_scope(connection).include?(profile)

      policies = Array(connection.destination_policies).map(&:stringify_keys).select do |policy|
        policy["profile"] == profile
      end
      policies
    end

    def self.valid_limit(value)
      parsed = Integer(value.presence || DEFAULT_LIMIT, exception: false)
      raise AdapterRequestBoundary::Error, "malformed_value" unless parsed&.between?(1, MAXIMUM_ITEMS)

      parsed
    end

    def self.valid_label?(value, maximum = 255)
      value.is_a?(String) && value.valid_encoding? && value.present? && value == value.strip &&
        value.bytesize <= maximum && !CONTROL_PATTERN.match?(value)
    end

    def self.stringify(value)
      value.respond_to?(:deep_stringify_keys) ? value.deep_stringify_keys : value
    end
    private_class_method :stringify

    def self.exact_keys!(value, keys)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        value.is_a?(Hash) && value.keys.map(&:to_s).sort == keys.sort
    end
    private_class_method :exact_keys!

    def self.validate_item!(segment_type, item)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        valid_label?(item["id"]) && valid_label?(item["name"]) && [true, false].include?(item["available"])

      case segment_type
      when "containers"
        raise AdapterRequestBoundary::Error, "validation_failed" unless valid_label?(item["kind"])
      when "taxonomies"
        raise AdapterRequestBoundary::Error, "validation_failed" if [true, false].exclude?(item["hierarchical"])
      when "terms"
        raise AdapterRequestBoundary::Error, "validation_failed" unless valid_label?(item["taxonomy_id"])
        raise AdapterRequestBoundary::Error, "validation_failed" unless
          item["parent_id"].nil? || valid_label?(item["parent_id"])
      when "presentation_modes"
        raise AdapterRequestBoundary::Error, "validation_failed" if
          ConnectionCapability::PRESENTATION_MODES.exclude?(item["id"])
      when "native_limits"
        raise AdapterRequestBoundary::Error, "validation_failed" unless
          item["maximum_bytes"].is_a?(Integer) && item["maximum_bytes"].positive? &&
            OVERFLOW_BEHAVIORS.include?(item["overflow_behavior"])
      end
    end
    private_class_method :validate_item!
  end
end
