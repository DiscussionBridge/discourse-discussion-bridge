# frozen_string_literal: true

require "base64"

module DiscussionBridge
  class OperatorEncoding
    BASE64URL_PATTERN = /\A[A-Za-z0-9_-]+\z/

    def self.decode_base64url(value, expected_bytes:)
      encoded = value.to_s
      return nil unless BASE64URL_PATTERN.match?(encoded)

      padding = "=" * ((4 - encoded.length % 4) % 4)
      raw = Base64.urlsafe_decode64(encoded + padding)
      return nil unless raw.bytesize == expected_bytes
      return nil unless Base64.urlsafe_encode64(raw, padding: false) == encoded

      raw
    rescue ArgumentError
      nil
    end
  end
end
