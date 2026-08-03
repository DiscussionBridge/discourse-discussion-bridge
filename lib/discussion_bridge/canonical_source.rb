# frozen_string_literal: true

require "uri"
require "digest"

module DiscussionBridge
  class CanonicalSource
    MAX_CONNECTION_ID_LENGTH = 100
    MAX_SOURCE_URL_LENGTH = 2048
    Result = Data.define(:connection_id, :source_url, :identity_digest)

    def self.call(connection_id:, source_url:)
      connection = connection_id.to_s.strip
      raise ArgumentError, "connection_id is required" if connection.empty?
      raise ArgumentError, "connection_id is too long" if connection.length > MAX_CONNECTION_ID_LENGTH

      raw_source_url = source_url.to_s
      raise ArgumentError, "source_url is too long" if raw_source_url.bytesize > MAX_SOURCE_URL_LENGTH

      uri = URI.parse(raw_source_url)
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise ArgumentError, "source_url must be an absolute HTTP(S) URL without credentials, a query, or a fragment"
      end

      uri.scheme = uri.scheme.downcase
      uri.host = uri.host.downcase
      uri.path = "/" if uri.path.empty?
      uri.path = uri.path.gsub(%r{/+}, "/")

      normalized = uri.normalize.to_s
      identity_digest = Digest::SHA256.hexdigest("#{connection}\n#{normalized}")
      Result.new(connection_id: connection, source_url: normalized, identity_digest: identity_digest)
    rescue URI::InvalidURIError
      raise ArgumentError, "source_url must be an absolute HTTP(S) URL"
    end
  end
end
