# frozen_string_literal: true

module DiscussionBridge
  # Value-local candidate grammar and an explicitly captured native segment.
  # Neither reference pins nor excerpt hashes independently prove native source.
  module CmsGeneratedExcerpt
    GENERATED_PREFIX = '<p data-discussionbridge-generated="read-more"><a href="'
    GENERATED_SUFFIX = '">Read More</a></p>'
    MARKER = "data-discussionbridge-generated"
    ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;" }.freeze
    EMPTY_ARTICLE = /\A[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]*\z/
    MEASUREMENT_ID = "11111111-1111-4111-8111-111111111111"

    def self.generated?(input)
      input.dig("representation", "kind") == "generated_excerpt"
    end

    def self.link(url)
      CmsProtocol.validate!("Url", url)
      GENERATED_PREFIX + url.gsub(/[&<>"']/) { |character| ESCAPES.fetch(character) } + GENERATED_SUFFIX
    end

    def self.article(input)
      representation = input.fetch("representation")
      count = representation.fetch("article_content_bytes").to_i
      bytes = input.fetch("content_html").b
      prefix = bytes.byteslice(0, count)&.force_encoding(Encoding::UTF_8)
      unless prefix && prefix.bytesize == count && prefix.valid_encoding? && !EMPTY_ARTICLE.match?(prefix) &&
          !prefix.downcase.include?(MARKER) && Digest::SHA256.hexdigest(prefix.b) == representation.fetch("article_content_sha256") &&
          bytes.byteslice(count..-1) == link(representation.fetch("read_more_url")).b
        CmsProtocol.reject!("invalid_field")
      end
      prefix
    end

    def self.validate_record!(input)
      representation = input.fetch("representation")
      valid_selection = representation.fetch("read_more_url") == input.fetch("canonical_url") &&
          (input.fetch("source_content_bytes") > 49_152 || representation.fetch("selection_full_request_bytes") > 65_536)
      unless valid_selection
        CmsProtocol.reject!("invalid_field")
      end
      article(input)
      input
    end

    def self.validate_selection!(input, trusted_current = nil)
      CmsProtocol.validate!("ToRecord", input)
      if trusted_current && input.fetch("source_revision") == trusted_current.fetch("source_revision")
        CmsProtocol.validate!("ToRecord", trusted_current)
        unless CmsToPublication.identity(input) == CmsToPublication.identity(trusted_current)
          CmsProtocol.reject!("identity_conflict")
        end
        return input
      end
      representation = input.fetch("representation")
      unless representation.fetch("selection_source_revision") == input.fetch("source_revision")
        CmsProtocol.reject!("invalid_field")
      end
      if input.fetch("source_content_bytes") <= 49_152
        full = input.reject { |key, _| %w[adapter_id adapter_version correlation_id].include?(key) }
          .merge("content_html" => "", "representation" => { "kind" => "full" })
        overhead = CmsProtocol.semantic_identity({ "mutation_id" => MEASUREMENT_ID, "bridge_record" => full }).bytesize
        size = representation.fetch("selection_full_request_bytes")
        count = input.fetch("source_content_bytes")
        CmsProtocol.reject!("invalid_field") unless size.between?(overhead + count, overhead + 6 * count)
      end
      input
    end

    def self.validate_envelope!(input)
      CmsProtocol.reject!("body_too_large") if input.fetch("content_html").bytesize > 49_152
      CmsProtocol.validate!("ToRecord", input)
      body = CmsProtocol.semantic_identity({ "mutation_id" => MEASUREMENT_ID, "bridge_record" => input })
      CmsProtocol.reject!("body_too_large") if body.bytesize > 65_536
      input
    end

    def self.project_move(input, url, revision, updated_at)
      CmsProtocol.validate!("ToRecord", input)
      CmsProtocol.validate!("Url", url)
      CmsProtocol.validate!("Revision", revision)
      CmsProtocol.validate!("Instant", updated_at) unless updated_at.nil?
      CmsProtocol.reject!("invalid_field") if url == input.fetch("canonical_url") || revision == input.fetch("source_revision")
      projected = JSON.parse(JSON.generate(input))
      projected.merge!("canonical_url" => url, "source_revision" => revision,
        "expected_source_revision" => input.fetch("source_revision"), "source_updated_at" => updated_at,
        "content_html" => article(input) + link(url))
      projected.fetch("representation")["read_more_url"] = url
      validate_envelope!(projected)
    end

    def self.normalized_segment(url)
      TextCleaner.normalize_whitespaces(PortableContent.to_discourse_raw(link(url))).rstrip
    end

    def self.capture_native(input, raw)
      segment = normalized_segment(input.fetch("canonical_url"))
      bytes = raw.b
      offset = bytes.index(segment.b)
      unless offset && !bytes.index(segment.b, offset + segment.bytesize)
        CmsProtocol.reject!("native_ownership_conflict")
      end
      { "raw" => segment, "offset_bytes" => offset,
        "prefix_sha256" => Digest::SHA256.hexdigest(bytes.byteslice(0, offset)),
        "suffix_sha256" => Digest::SHA256.hexdigest(bytes.byteslice(offset + segment.bytesize..-1)) }
    end

    def self.replace_native(owned, raw, url)
      CmsProtocol.reject!("native_ownership_conflict") unless owned.is_a?(Hash)
      bytes = raw.b
      offset = owned.fetch("offset_bytes")
      segment = owned.fetch("raw").b
      prefix = bytes.byteslice(0, offset)
      suffix = bytes.byteslice(offset + segment.bytesize..-1)
      unless prefix && suffix && bytes.byteslice(offset, segment.bytesize) == segment &&
          Digest::SHA256.hexdigest(prefix) == owned.fetch("prefix_sha256") &&
          Digest::SHA256.hexdigest(suffix) == owned.fetch("suffix_sha256")
        CmsProtocol.reject!("native_ownership_conflict")
      end
      (prefix + normalized_segment(url).b + suffix).force_encoding(Encoding::UTF_8)
    rescue KeyError, TypeError
      CmsProtocol.reject!("native_ownership_conflict")
    end
  end
end
