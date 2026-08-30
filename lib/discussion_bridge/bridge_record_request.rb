# frozen_string_literal: true

require "json"

module DiscussionBridge
  module BridgeRecordRequest
    MAX_JSON_BYTES = 64 * 1024
    MAX_CONTENT_HTML_BYTES = 48 * 1024
    MAX_EXTERNAL_ID_BYTES = 255
    MAX_CORRELATION_ID_BYTES = 200
    MAX_SOURCE_AUTHORS = 20
    MAX_SOURCE_AUTHOR_ID_BYTES = 255
    MAX_SOURCE_AUTHOR_NAME_BYTES = 200
    MAX_TOPIC_ID = 9_223_372_036_854_775_807
    REQUIRED_KEYS = %w[direction external_id canonical_url title content_html published].freeze
    ALLOWED_KEYS = (
      REQUIRED_KEYS + %w[
        lane
        adapter_id
        adapter_version
        correlation_id
        visibility
        source_authors
        primary_source_author_id
        existing_topic_id
      ]
    ).freeze
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
      validate_content_html!(raw["content_html"])

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
      validate_source_authors!(raw)
      if raw.key?("existing_topic_id")
        existing_topic_id = raw["existing_topic_id"]
        unless existing_topic_id.is_a?(Integer) && existing_topic_id.between?(1, MAX_TOPIC_ID)
          raise ArgumentError, "invalid existing_topic_id"
        end
      end

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

    def self.validate_content_html!(value)
      invalid_controls = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/
      valid = value.is_a?(String) && value.valid_encoding? && value.strip.present? &&
        value.bytesize <= MAX_CONTENT_HTML_BYTES && !invalid_controls.match?(value)
      raise ArgumentError, "invalid content_html" unless valid
    end
    private_class_method :validate_content_html!

    def self.validate_source_authors!(raw)
      authors = raw["source_authors"]
      primary_id = raw["primary_source_author_id"]
      if authors.nil?
        raise ArgumentError, "primary source author requires source authors" if primary_id.present?
        return
      end

      unless authors.is_a?(Array) && authors.length.between?(1, MAX_SOURCE_AUTHORS)
        raise ArgumentError, "invalid source authors"
      end

      normalized = authors.map do |author|
        raise ArgumentError, "invalid source author" unless author.is_a?(Hash)

        author = author.stringify_keys
        raise ArgumentError, "invalid source author schema" unless (author.keys - %w[id name profile_url]).empty?
        raise ArgumentError, "invalid source author schema" unless %w[id name].all? { |key| author.key?(key) }
        validate_string!(author["id"], "source author id", MAX_SOURCE_AUTHOR_ID_BYTES, identifier: false)
        validate_string!(author["name"], "source author name", MAX_SOURCE_AUTHOR_NAME_BYTES, identifier: false)
        if author.key?("profile_url")
          validate_string!(
            author["profile_url"],
            "source author profile URL",
            CanonicalSource::MAX_SOURCE_URL_LENGTH,
            identifier: false,
          )
          author["profile_url"] = CanonicalSource.call(
            connection_id: "author-profile-validation",
            source_url: author["profile_url"],
          ).source_url
        end
        author
      end

      ids = normalized.map { |author| author.fetch("id") }
      raise ArgumentError, "duplicate source author identity" unless ids.uniq.length == ids.length
      validate_string!(primary_id, "primary source author id", MAX_SOURCE_AUTHOR_ID_BYTES, identifier: false)
      raise ArgumentError, "primary source author is not present" if ids.exclude?(primary_id)

      raw["source_authors"] = normalized
    end
    private_class_method :validate_source_authors!
  end
end
