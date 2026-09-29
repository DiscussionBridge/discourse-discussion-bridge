# frozen_string_literal: true

require "digest"

module DiscussionBridge
  module NetworkSourceDetail
    DETAIL_FIELDS = SourcePublicationProtocol::DETAIL_FIELDS
    CONTENT_MODES = %w[inline chunked].freeze

    def self.call(payload:, content_html: nil)
      raw = exact_object!(payload, DETAIL_FIELDS)
      validate_label!(raw["resource_id"], 64)
      unless raw["topic_id"].is_a?(Integer) && raw["topic_id"].positive?
        raise AdapterRequestBoundary::Error, "validation_failed"
      end
      raw["topic_url"] = canonical_https_url!(raw["topic_url"])
      validate_label!(raw["title"], ConnectionRequest::MAX_TITLE_BYTES)
      validate_label!(raw["source_revision"], 255)
      unless raw["source_revision_sequence"].is_a?(Integer) && raw["source_revision_sequence"].positive?
        raise AdapterRequestBoundary::Error, "validation_failed"
      end
      source_created_at = BridgeRecordRequest.send(
        :validate_timestamp!,
        raw["source_created_at"],
        "source_created_at",
      )
      source_updated_at = BridgeRecordRequest.send(
        :validate_timestamp!,
        raw["source_updated_at"],
        "source_updated_at",
      )
      raise AdapterRequestBoundary::Error, "validation_failed" if
        source_updated_at < source_created_at
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        raw["source_authors"].is_a?(Array) && raw["categories"].is_a?(Array) &&
          raw["tags"].is_a?(Array)
      raise AdapterRequestBoundary::Error, "validation_failed" if
        ConnectionCapability::PRESENTATION_MODES.exclude?(raw["presentation_mode"])
      raise AdapterRequestBoundary::Error, "validation_failed" if
        BridgeRecordRequest::CONTENT_DISPOSITIONS.exclude?(raw["content_disposition"])
      validate_label!(raw["correlation_id"], 200)

      transport = raw.fetch("content_transport")
      mode = transport.is_a?(Hash) && transport["mode"]
      raise AdapterRequestBoundary::Error, "validation_failed" if CONTENT_MODES.exclude?(mode)
      fields = mode == "inline" ?
        SourcePublicationProtocol::INLINE_TRANSPORT_FIELDS :
        SourcePublicationProtocol::CHUNK_DESCRIPTOR_FIELDS
      exact_object!(transport, fields)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        transport["media_type"] == SourcePublicationProtocol::MEDIA_TYPE
      byte_length = transport["byte_length"]
      unless byte_length.is_a?(Integer) &&
          byte_length.between?(1, SourcePublicationProtocol::MAXIMUM_SOURCE_CONTENT_BYTES)
        raise AdapterRequestBoundary::Error, "validation_failed"
      end
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        SourcePublicationProtocol::SHA256_PATTERN.match?(transport["sha256"].to_s)

      materialized = content_html || transport["content_html"]
      materialized = materialized.dup.force_encoding(Encoding::UTF_8) if materialized.is_a?(String)
      unless materialized.is_a?(String) && materialized.valid_encoding? &&
          materialized.bytesize == byte_length &&
          Digest::SHA256.hexdigest(materialized) == transport["sha256"]
        raise AdapterRequestBoundary::Error, "integrity_failed"
      end
      raw["content_html"] = materialized
      raw
    end

    def self.exact_object!(value, fields)
      unless value.is_a?(Hash) && value.keys.map(&:to_s).sort == fields.sort
        raise AdapterRequestBoundary::Error, "validation_failed"
      end

      value.deep_stringify_keys
    end
    private_class_method :exact_object!

    def self.validate_label!(value, maximum)
      valid = value.is_a?(String) && value.valid_encoding? && value.present? &&
        value == value.strip && value.bytesize <= maximum && !/[\x00-\x1f\x7f]/.match?(value)
      raise AdapterRequestBoundary::Error, "validation_failed" unless valid
    end
    private_class_method :validate_label!

    def self.canonical_https_url!(value)
      canonical = CanonicalSource.call(connection_id: "network-source", source_url: value.to_s).source_url
      raise AdapterRequestBoundary::Error, "validation_failed" unless URI.parse(canonical).scheme == "https"

      canonical
    rescue ArgumentError, URI::InvalidURIError
      raise AdapterRequestBoundary::Error, "validation_failed"
    end
    private_class_method :canonical_https_url!
  end
end
