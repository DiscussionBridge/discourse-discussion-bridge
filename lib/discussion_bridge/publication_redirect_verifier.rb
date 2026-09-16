# frozen_string_literal: true

require "uri"

module DiscussionBridge
  class PublicationRedirectVerifier
    def self.call(old_url:, new_url:)
      new(old_url: old_url, new_url: new_url).call
    end

    def initialize(old_url:, new_url:)
      @old_url = old_url
      @new_url = new_url
    end

    def call
      old_uri = secure_uri(@old_url)
      new_uri = secure_uri(@new_url)
      raise ArgumentError, "publication redirect must remain on the same origin" unless
        old_uri.scheme == new_uri.scheme && old_uri.host == new_uri.host && old_uri.port == new_uri.port
      raise ArgumentError, "publication URLs must differ" if old_uri == new_uri

      old_status, location = probe(old_uri)
      raise ArgumentError, "old publication URL does not return a permanent redirect" unless
        [301, 308].include?(old_status)
      raise ArgumentError, "old publication redirect has no destination" if location.blank?
      resolved = URI.join(old_uri.to_s, location).to_s
      raise ArgumentError, "old publication URL redirects to a different destination" unless
        resolved == new_uri.to_s

      destination_status, = probe(new_uri)
      raise ArgumentError, "new publication URL is not publicly available" unless
        destination_status == 200

      old_status
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid publication redirect URL"
    end

    private

    def secure_uri(value)
      uri = URI.parse(value)
      raise ArgumentError, "publication redirect requires an HTTPS URL" unless
        uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? &&
          uri.query.nil? && uri.fragment.nil? && uri.host.present?
      uri
    end

    def probe(uri)
      result = nil
      catch(:headers_read) do
        # FinalDestination::HTTP filters resolved private IPs at connect time.
        # This request deliberately never follows a Location header.
        FinalDestination::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: 5,
        ) do |http|
          http.read_timeout = 5
          http.request_get(uri.request_uri, { "Accept" => "text/html", "User-Agent" => "DiscussionBridge-Redirect-Verification" }) do |response|
            result = [response.code.to_i, response["location"]]
            throw :headers_read
          end
        end
      end
      result || raise(ArgumentError, "publication redirect did not return headers")
    rescue StandardError
      raise ArgumentError, "publication redirect verification failed"
    end
  end
end
