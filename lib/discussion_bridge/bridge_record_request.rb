# frozen_string_literal: true

require "json"

module DiscussionBridge
  module BridgeRecordRequest
    MAX_JSON_BYTES = 64 * 1024
    MAX_EXTERNAL_ID_BYTES = 255
    MAX_CORRELATION_ID_BYTES = 200
    REQUIRED_KEYS = %w[direction external_id canonical_url title published].freeze
    ALLOWED_KEYS = (REQUIRED_KEYS + %w[lane adapter_id adapter_version correlation_id visibility]).freeze
    IDENTIFIER_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/
    CONTROL_PATTERN = /[\x00-\x1f\x7f]/

    def self.call(parameters)
      raise ArgumentError, "bridge_record must be an object" unless parameters.is_a?(ActionController::Parameters)

      raw = parameters.to_unsafe_h.stringify_keys
      raise ArgumentError, "bridge record payload is too large" if JSON.generate(raw).bytesize > MAX_JSON_BYTES
      raise ArgumentError, "invalid bridge record schema" unless (raw.keys - ALLOWED_KEYS).empty?
      raise ArgumentError, "missing bridge record field" unless (REQUIRED_KEYS - raw.keys).empty?
      raise ArgumentError, "content must be authoritatively published" unless raw["published"] == true
      raise ArgumentError, "invalid direction" unless raw["direction"] == "to_discourse"

      validate_string!(raw["external_id"], "external_id", MAX_EXTERNAL_ID_BYTES, identifier: false)
      validate_string!(raw["canonical_url"], "canonical_url", CanonicalSource::MAX_SOURCE_URL_LENGTH, identifier: false)
      validate_string!(raw["title"], "title", ConnectionRequest::MAX_TITLE_BYTES, identifier: false, strip: false)
      unless raw["title"].length.between?(SiteSetting.min_topic_title_length, SiteSetting.max_topic_title_length)
        raise ArgumentError, "invalid title"
      end

      %w[lane adapter_id adapter_version correlation_id visibility].each do |key|
        next unless raw.key?(key)
        maximum = case key
                  when "lane" then ConnectionRequest::MAX_LANE_BYTES
                  when "adapter_id", "adapter_version" then ConnectionRequest::MAX_ADAPTER_ID_BYTES
                  when "correlation_id" then MAX_CORRELATION_ID_BYTES
                  else ConnectionRequest::MAX_VISIBILITY_BYTES
                  end
        validate_string!(raw[key], key, maximum, identifier: key != "visibility")
      end
      raise ArgumentError, "invalid lane" if raw.key?("lane") && !LanePolicies::LANE_PATTERN.match?(raw["lane"])
      raise ArgumentError, "invalid visibility" if raw.key?("visibility") && raw["visibility"] != "unlisted"

      raw.symbolize_keys
    rescue JSON::GeneratorError
      raise ArgumentError, "invalid bridge record payload"
    end

    def self.validate_string!(value, name, maximum, identifier:, strip: true)
      valid = value.is_a?(String) && value.valid_encoding? && value.present? &&
        value.bytesize <= maximum && !CONTROL_PATTERN.match?(value) && (!strip || value == value.strip)
      valid &&= IDENTIFIER_PATTERN.match?(value) if identifier
      raise ArgumentError, "invalid #{name}" unless valid
    end
    private_class_method :validate_string!
  end
end
