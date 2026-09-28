# frozen_string_literal: true

require "uri"

module DiscussionBridge
  class PublicationRedirectVerifier
    def self.call(old_url:, new_url:, allow_cross_origin: false)
      new(
        old_url: old_url,
        new_url: new_url,
        allow_cross_origin: allow_cross_origin,
      ).call
    end

    def initialize(old_url:, new_url:, allow_cross_origin:)
      @old_url = old_url
      @new_url = new_url
      @allow_cross_origin = allow_cross_origin
    end

    def call
      old_uri = secure_uri(@old_url)
      new_uri = secure_uri(@new_url)
      raise ArgumentError, "URL migration requires distinct URLs" if old_uri == new_uri
      unless @allow_cross_origin || same_origin?(old_uri, new_uri)
        raise ArgumentError, "cross-origin migration requires explicit operator approval"
      end

      old_status, location = probe(old_uri)
      raise ArgumentError, "retired URL does not return a permanent redirect" if
        [301, 308].exclude?(old_status)
      raise ArgumentError, "retired URL redirect has no destination" if location.blank?

      resolved = URI.join(old_uri.to_s, location).to_s
      raise ArgumentError, "retired URL redirects to a different destination" unless
        resolved == new_uri.to_s

      destination_status, = probe(new_uri)
      raise ArgumentError, "new URL is not publicly available" unless destination_status == 200

      old_status
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid URL migration target"
    end

    private

    def secure_uri(value)
      uri = URI.parse(value)
      valid = uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? &&
        uri.query.nil? && uri.fragment.nil? && uri.host.present?
      raise ArgumentError, "URL migration requires a canonical HTTPS URL" unless valid

      uri
    end

    def same_origin?(left, right)
      left.scheme == right.scheme && left.host == right.host && left.port == right.port
    end

    def probe(uri)
      result = nil
      catch(:headers_read) do
        FinalDestination::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: 5,
        ) do |http|
          http.read_timeout = 5
          http.request_get(
            uri.request_uri,
            {
              "Accept" => "text/html",
              "User-Agent" => "DiscussionBridge-Redirect-Verification",
            },
          ) do |response|
            result = [response.code.to_i, response["location"]]
            throw :headers_read
          end
        end
      end
      result || raise(ArgumentError, "URL verification returned no headers")
    rescue StandardError
      raise ArgumentError, "URL verification failed"
    end
  end
end
