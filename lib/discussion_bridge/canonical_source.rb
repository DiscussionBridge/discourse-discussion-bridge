# frozen_string_literal: true

require "uri"
require "digest"
require "ipaddr"

module DiscussionBridge
  class CanonicalSource
    MAX_CONNECTION_ID_LENGTH = 100
    MAX_SOURCE_URL_LENGTH = 2048
    MAX_PATH_DECODE_PASSES = 4
    MAX_DNS_HOST_BYTES = 253
    MAX_DNS_LABEL_BYTES = 63
    Result = Data.define(:connection_id, :source_url, :identity_digest)

    def self.origin(source_url)
      result = call(connection_id: "origin-validation", source_url: source_url)
      uri = URI.parse(result.source_url)
      raise ArgumentError, "origin must not include a path" unless uri.path == "/"

      normalized = "#{uri.scheme}://#{uri.host}"
      normalized += ":#{uri.port}" unless uri.port == uri.default_port
      normalized
    end

    def self.call(connection_id:, source_url:)
      connection = connection_id.to_s.strip
      raise ArgumentError, "connection_id is required" if connection.empty?
      raise ArgumentError, "connection_id is too long" if connection.length > MAX_CONNECTION_ID_LENGTH

      raw_source_url = source_url.to_s
      raise ArgumentError, "source_url is too long" if raw_source_url.bytesize > MAX_SOURCE_URL_LENGTH

      uri = URI.parse(raw_source_url)
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? &&
        uri.query.nil? && uri.fragment.nil?
        raise ArgumentError, "source_url must be an absolute HTTP(S) URL without credentials, a query, or a fragment"
      end
      validate_path!(uri.path)
      validate_host!(uri.host)

      uri.scheme = uri.scheme.downcase
      uri.host = uri.host.downcase
      uri.port = nil if uri.port == uri.default_port
      uri.path = canonical_path(uri.path.empty? ? "/" : uri.path)

      normalized = uri.normalize.to_s
      identity_digest = Digest::SHA256.hexdigest("#{connection}\n#{normalized}")
      Result.new(connection_id: connection, source_url: normalized, identity_digest: identity_digest)
    rescue URI::InvalidURIError
      raise ArgumentError, "source_url must be an absolute HTTP(S) URL"
    end

    def self.validate_path!(path)
      candidate = path
      (MAX_PATH_DECODE_PASSES + 1).times do |pass|
        raise ArgumentError, "source_url path contains invalid encoding" unless candidate.valid_encoding?
        if candidate.match?(/%(?![0-9a-f]{2})/i)
          raise ArgumentError, "source_url path contains invalid percent encoding"
        end
        raise ArgumentError, "source_url path contains an ambiguous separator or traversal segment" if
          candidate.include?("//") || candidate.include?("\\") || candidate.match?(/%(?:2f|5c)/i) ||
            candidate.match?(/[\x00-\x1f\x7f]/) ||
            candidate.split("/").any? { |segment| %w[. ..].include?(segment) }

        decoded = URI::DEFAULT_PARSER.unescape(candidate)
        break if decoded == candidate
        raise ArgumentError, "source_url path remains ambiguously encoded" if pass == MAX_PATH_DECODE_PASSES
        candidate = decoded
      end
    end
    private_class_method :validate_path!

    def self.validate_host!(host)
      if host.end_with?(".")
        raise ArgumentError, "source_url host must not have a trailing dot"
      end
      if host.include?("%")
        raise ArgumentError, "source_url host must not be percent encoded"
      end

      numeric_candidate = host.delete_prefix("[").delete_suffix("]")
      components = numeric_candidate.split(".", -1)
      numeric = components.length.between?(1, 4) && components.all? { |component|
        component.match?(/\A(?:0x[0-9a-f]+|[0-9]+)\z/i)
      }
      begin
        IPAddr.new(numeric_candidate)
        numeric = true
      rescue IPAddr::InvalidAddressError
        # Non-numeric DNS reg-name.
      end
      raise ArgumentError, "source_url host must be a DNS name" if numeric

      labels = host.split(".", -1)
      valid_dns = host.bytesize <= MAX_DNS_HOST_BYTES && labels.all? { |label|
        label.bytesize.between?(1, MAX_DNS_LABEL_BYTES) &&
          label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/i)
      }
      raise ArgumentError, "source_url host must be a valid ASCII DNS name" unless valid_dns
    end
    private_class_method :validate_host!

    def self.canonical_path(path)
      normalized = path.gsub(/%([0-9a-f]{2})/i) do
        byte = Regexp.last_match(1).to_i(16)
        unreserved_byte?(byte) ? byte.chr(Encoding::UTF_8) : format("%%%02X", byte)
      end
      normalized.sub(%r{/index/\z}i, "/")
    end
    private_class_method :canonical_path

    def self.unreserved_byte?(byte)
      byte.between?(0x41, 0x5a) || byte.between?(0x61, 0x7a) || byte.between?(0x30, 0x39) ||
        [0x2d, 0x2e, 0x5f, 0x7e].include?(byte)
    end
    private_class_method :unreserved_byte?
  end
end
