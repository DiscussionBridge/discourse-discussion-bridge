# frozen_string_literal: true

require "digest"
require "json"
require "time"

module DiscussionBridge
  module SourcePublication
    KEYS = %w[
      revision
      previous_revision
      created_at
      updated_at
      content_sha256
      content_bytes
      excerpted
    ].freeze
    SHA256 = /\A[0-9a-f]{64}\z/
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z/

    def self.call(value, request:)
      raise ArgumentError, "invalid source_publication" unless value.is_a?(Hash)
      value = value.stringify_keys
      raise ArgumentError, "invalid source_publication schema" unless value.keys.sort == KEYS.sort
      %w[revision content_sha256].each do |key|
        unless value[key].is_a?(String) && SHA256.match?(value[key])
          raise ArgumentError, "invalid source_publication #{key}"
        end
      end
      previous = value["previous_revision"]
      valid_previous = previous.nil? || (previous.is_a?(String) && SHA256.match?(previous))
      raise ArgumentError, "invalid previous_revision" unless valid_previous
      created_at = timestamp(value["created_at"])
      updated_at = timestamp(value["updated_at"])
      if created_at && updated_at && updated_at < created_at
        raise ArgumentError, "invalid source publication dates"
      end
      bytes = value["content_bytes"]
      unless bytes.is_a?(Integer) && bytes.between?(1, 9_007_199_254_740_991)
        raise ArgumentError, "invalid content_bytes"
      end
      raise ArgumentError, "invalid excerpted" if [true, false].exclude?(value["excerpted"])
      html = request.fetch("content_html")
      if value["excerpted"]
        canonical =
          CanonicalSource.call(
            connection_id: "excerpt-validation",
            source_url: request.fetch("canonical_url"),
          ).source_url
        fragment = Nokogiri::HTML5.fragment(html)
        read_more =
          fragment
            .css("a[href]")
            .any? do |anchor|
              anchor.text.strip.casecmp?("Read More") && anchor["href"] == canonical
            end
        raise ArgumentError, "excerpt requires canonical Read More" unless read_more
      elsif html.bytesize != bytes || Digest::SHA256.hexdigest(html) != value["content_sha256"]
        raise ArgumentError, "source content digest mismatch"
      end
      value
    end

    def self.timestamp(value)
      return nil if value.nil?
      unless value.is_a?(String) && value.bytesize <= 64 && TIMESTAMP.match?(value)
        raise ArgumentError, "invalid source publication timestamp"
      end
      time = Time.iso8601(value)
      unless time.strftime("%Y-%m-%d") == value[0, 10]
        raise ArgumentError, "invalid source publication date"
      end
      time
    end
    private_class_method :timestamp

    def self.request_sha256(request)
      authors =
        Array(request[:source_authors]).map do |author|
          [author.fetch("id"), author.fetch("name"), author["profile_url"]]
        end
      Digest::SHA256.hexdigest(
        JSON.generate(
          [
            request.fetch(:title),
            request.fetch(:content_html),
            authors,
            request[:primary_source_author_id],
          ],
        ),
      )
    end

    def self.managed_native_sha256(topic, first_post)
      Digest::SHA256.hexdigest(
        JSON.generate([topic.id, topic.title, first_post.id, first_post.raw, first_post.user_id]),
      )
    end

    def self.same_edition?(stored, incoming, request)
      (KEYS - ["previous_revision"]).all? { |key| stored[key] == incoming[key] } &&
        stored["request_sha256"] == request_sha256(request)
    end

    def self.receipt(incoming, request, topic, first_post)
      incoming.merge(
        "request_sha256" => request_sha256(request),
        "managed_native_sha256" => managed_native_sha256(topic, first_post),
      )
    end
  end
end
