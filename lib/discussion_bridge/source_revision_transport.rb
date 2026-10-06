# frozen_string_literal: true

require "base64"
require "digest"

module DiscussionBridge
  # Exact retained revisions only. Neither a mutable first-post read nor an
  # arbitrary first binding is a substitute for the requested source context.
  class SourceRevisionTransport
    INLINE_BYTES = 49_152
    CHUNK_BYTES = 32_768
    DETAIL_JSON_BYTES = 262_144
    MAX_INTEGER = 9_007_199_254_740_991
    METADATA_FIELDS = %w[title topic_url source_created_at source_updated_at source_authors categories tags].freeze

    def initialize(record:, binding:, revision:)
      @record = record
      @binding = binding
      @capture = record.native_source_revisions.select(
        :id, :bridge_record_id, :sequence, :revision, :fingerprint, :metadata,
      ).lock.find_by(revision: revision)
      fail_with("revision_not_found") unless @capture
      @metadata = @capture.metadata
      verify_context!
    end

    def detail(correlation_id:)
      value = {
        resource_id: @record.resource_id, topic_id: @record.topic_id,
        topic_url: @metadata.fetch("topic_url"), title: @metadata.fetch("title"),
        source_revision: @capture.revision, source_revision_sequence: @capture.sequence,
        source_created_at: @metadata.fetch("source_created_at"), source_updated_at: @metadata.fetch("source_updated_at"),
        source_authors: @metadata.fetch("source_authors"), categories: @metadata.fetch("categories"),
        tags: @metadata.fetch("tags"), presentation_mode: @binding.presentation_mode,
        content_disposition: "complete", network_provenance: nil, correlation_id: correlation_id,
      }
      descriptor = { mode: "chunked", media_type: "text/html; charset=utf-8",
                     byte_length: @bytes, sha256: @sha256,
                     chunk_count: chunk_count, decoded_chunk_maximum_bytes: CHUNK_BYTES }
      value[:content_transport] = descriptor
      if @bytes <= INLINE_BYTES
        html = content_slice(0, @bytes).force_encoding(Encoding::UTF_8)
        fail_with("integrity_failed") unless html.valid_encoding?
        inline = descriptor.except(:chunk_count, :decoded_chunk_maximum_bytes).merge(mode: "inline", content_html: html)
        value[:content_transport] = inline
        # Escaping is part of the wire bound, even below the inline byte bound.
        value[:content_transport] = descriptor if JSON.generate(value).bytesize > DETAIL_JSON_BYTES
      end
      fail_with("content_unsupported") if JSON.generate(value).bytesize > DETAIL_JSON_BYTES
      value
    end

    def chunk(number:, correlation_id:)
      fail_with("validation_failed") unless number.is_a?(Integer) && number.between?(1, chunk_count)
      bytes = content_slice((number - 1) * CHUNK_BYTES, CHUNK_BYTES)
      { source_revision: @capture.revision, chunk: number, chunk_count: chunk_count,
        decoded_bytes: bytes.bytesize, chunk_sha256: Digest::SHA256.hexdigest(bytes),
        content_base64: Base64.strict_encode64(bytes), correlation_id: correlation_id }
    end

    private

    def verify_context!
      fail_with("reconciliation_required") unless @record.known_source_context? &&
        @metadata.is_a?(Hash) && (METADATA_FIELDS - @metadata.keys).empty? &&
        NativeSourceRevisionCapture.fingerprint(@metadata) == @capture.fingerprint &&
        @metadata["post_id"] == @record.topic.first_post.id &&
        @capture.sequence.between?(1, @record.source_revision_sequence) &&
        %w[simple full interactive].include?(@binding.presentation_mode)
      @bytes = @metadata["source_content_bytes"]
      @sha256 = @metadata["source_content_sha256"]
      fail_with("reconciliation_required") unless @bytes.is_a?(Integer) && @bytes.between?(0, MAX_INTEGER) &&
        @sha256.is_a?(String) && /\A[a-f0-9]{64}\z/.match?(@sha256)
      if @capture.sequence == @record.source_revision_sequence
        expected = @metadata.slice("title", "source_created_at", "source_updated_at", "source_content_bytes", "source_content_sha256")
        actual = { "title" => @record.title, "source_created_at" => @record.source_created_at_raw,
                   "source_updated_at" => @record.source_updated_at_raw, "source_content_bytes" => @record.source_content_bytes,
                   "source_content_sha256" => @record.source_content_sha256 }
        fail_with("reconciliation_required") unless expected == actual && @capture.revision == @record.source_revision &&
          @capture.fingerprint == @record.source_request_fingerprint
      end
      validate_metadata!
      # PostgreSQL verifies the whole retained UTF-8 body without loading a large
      # article into Ruby merely to send a descriptor or one bounded byte slice.
      size, hash = retained_relation.pick(Arel.sql("octet_length(content_html)"),
        Arel.sql("encode(sha256(convert_to(content_html, 'UTF8')), 'hex')"))
      fail_with("integrity_failed") unless size == @bytes && hash == @sha256
    end

    def validate_metadata!
      string!(@metadata["title"], 1024)
      public_url!(@metadata["topic_url"])
      created = BridgeRecordRequest.timestamp!(@metadata["source_created_at"])
      fail_with("reconciliation_required") if BridgeRecordRequest.timestamp!(@metadata["source_updated_at"]) < created
      authors = @metadata["source_authors"]
      fail_with("reconciliation_required") unless authors.is_a?(Array) && authors.length <= 20
      authors.each do |author|
        fields = %w[source_author_id source_author_name source_author_url]
        fail_with("reconciliation_required") unless author.is_a?(Hash) && author.keys.sort == fields.sort
        string!(author["source_author_id"], 255)
        string!(author["source_author_name"], 200)
        public_url!(author["source_author_url"])
      end
      validate_taxonomy!(@metadata["categories"], type: "category", maximum: 20)
      validate_taxonomy!(@metadata["tags"], type: "tag", maximum: 100)
    end

    def validate_taxonomy!(items, type:, maximum:)
      fail_with("reconciliation_required") unless items.is_a?(Array) && items.length <= maximum
      fields = ["source_#{type}_id", "source_#{type}_name"]
      fields << "source_parent_category_id" if type == "category"
      ids = items.map do |item|
        fail_with("reconciliation_required") unless item.is_a?(Hash) && item.keys.sort == fields.sort
        string!(item["source_#{type}_id"], 255)
        string!(item["source_#{type}_name"], 200)
        parent = item["source_parent_category_id"]
        string!(parent, 255) if type == "category" && !parent.nil?
        item["source_#{type}_id"]
      end
      fail_with("reconciliation_required") unless ids.uniq.length == ids.length
    end

    def string!(value, maximum)
      unless value.is_a?(String) && value.valid_encoding? && value.strip.present? &&
          value.bytesize <= maximum && !AdapterRequestBoundary::CONTROL_PATTERN.match?(value)
        fail_with("reconciliation_required")
      end
    end

    def public_url!(value)
      string!(value, 2048)
      normalized = CanonicalSource.call(connection_id: "source-validation", source_url: value).source_url
      fail_with("reconciliation_required") unless normalized == value
    rescue ArgumentError
      fail_with("reconciliation_required")
    end

    def retained_relation
      DiscussionBridgeNativeSourceRevision.where(id: @capture.id, bridge_record_id: @record.id)
    end

    def content_slice(offset, count)
      # Offsets are receiver-computed integers, never interpolated request text.
      value = retained_relation.pick(Arel.sql("substring(convert_to(content_html, 'UTF8') FROM #{offset + 1} FOR #{count})"))
      fail_with("revision_not_found") unless value
      value.b
    end

    def chunk_count
      [(@bytes + CHUNK_BYTES - 1) / CHUNK_BYTES, 1].max
    end

    def fail_with(code)
      raise AdapterRequestBoundary::Error.new(code)
    end
  end
end
