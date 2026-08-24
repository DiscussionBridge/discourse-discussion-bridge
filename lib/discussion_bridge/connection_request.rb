# frozen_string_literal: true

require "json"

module DiscussionBridge
  module ConnectionRequest
    MAX_JSON_BYTES = 64 * 1024
    MAX_TITLE_BYTES = 1024
    MAX_ADAPTER_ID_BYTES = 100
    MAX_VISIBILITY_BYTES = 32
    MAX_LANE_BYTES = 64
    MAX_CORRELATION_ID_BYTES = 200
    MAX_TAGS = 20
    MAX_TAG_BYTES = 100
    MAX_SAFE_INTEGER = 9_007_199_254_740_991
    MAX_SOURCE_URL_BYTES = CanonicalSource::MAX_SOURCE_URL_LENGTH
    MAX_CONNECTION_ID_BYTES = CanonicalSource::MAX_CONNECTION_ID_LENGTH
    REQUIRED_KEYS = %w[connection_id source_url title].freeze
    ALLOWED_KEYS = (
      REQUIRED_KEYS + %w[adapter_id visibility lane correlation_id category_id tags]
    ).freeze
    IDENTIFIER_LIMITS = {
      "connection_id" => MAX_CONNECTION_ID_BYTES,
      "adapter_id" => MAX_ADAPTER_ID_BYTES,
      "visibility" => MAX_VISIBILITY_BYTES,
      "lane" => MAX_LANE_BYTES,
      "correlation_id" => MAX_CORRELATION_ID_BYTES,
    }.freeze
    CONTROL_PATTERN = /[\x00-\x1f\x7f]/
    IDENTIFIER_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/

    def self.call(parameters)
      unless parameters.is_a?(ActionController::Parameters)
        raise ArgumentError, "connection must be an object"
      end

      raw = parameters.to_unsafe_h.stringify_keys
      raise ArgumentError, "connection payload is too large" if JSON.generate(raw).bytesize > MAX_JSON_BYTES
      raise ArgumentError, "invalid connection schema" unless (raw.keys - ALLOWED_KEYS).empty?
      raise ArgumentError, "missing connection field" unless (REQUIRED_KEYS - raw.keys).empty?

      IDENTIFIER_LIMITS.each do |key, maximum|
        next unless raw.key?(key)

        validate_string!(raw[key], key, maximum, strip: true)
      end
      validate_string!(raw.fetch("source_url"), "source_url", MAX_SOURCE_URL_BYTES, strip: true)
      validate_string!(raw.fetch("title"), "title", MAX_TITLE_BYTES, strip: false)
      title_length = raw.fetch("title").length
      unless title_length.between?(SiteSetting.min_topic_title_length, SiteSetting.max_topic_title_length)
        raise ArgumentError, "invalid title"
      end
      %w[connection_id adapter_id correlation_id].each do |key|
        next unless raw.key?(key)
        raise ArgumentError, "invalid #{key}" unless IDENTIFIER_PATTERN.match?(raw[key])
      end
      if raw.key?("lane") && !LanePolicies::LANE_PATTERN.match?(raw["lane"])
        raise ArgumentError, "invalid lane"
      end
      if raw.key?("visibility") && !%w[listed unlisted].include?(raw["visibility"])
        raise ArgumentError, "invalid visibility"
      end

      if raw.key?("category_id")
        category_id = raw["category_id"]
        if category_id.is_a?(String) && /\A[1-9]\d*\z/.match?(category_id)
          category_id = Integer(category_id, exception: false)
        end
        unless category_id.is_a?(Integer) && category_id.positive? && category_id <= MAX_SAFE_INTEGER
          raise ArgumentError, "invalid category_id"
        end
        raw["category_id"] = category_id
      end

      if raw.key?("tags")
        tags = raw["tags"]
        unless tags.is_a?(Array) && tags.length <= MAX_TAGS &&
          tags.all? { |tag| valid_string?(tag, MAX_TAG_BYTES, strip: true) } &&
          tags.map(&:downcase).uniq.length == tags.length
          raise ArgumentError, "invalid tags"
        end
      end

      raw.symbolize_keys
    rescue JSON::GeneratorError
      raise ArgumentError, "invalid connection payload"
    end

    def self.validate_string!(value, name, maximum, strip:)
      raise ArgumentError, "invalid #{name}" unless valid_string?(value, maximum, strip: strip)
    end
    private_class_method :validate_string!

    def self.valid_string?(value, maximum, strip:)
      value.is_a?(String) && value.valid_encoding? && value.present? && value.bytesize <= maximum &&
        !CONTROL_PATTERN.match?(value) && (!strip || value == value.strip)
    end
    private_class_method :valid_string?
  end
end
