# frozen_string_literal: true

module DiscussionBridge
  class ContentConnectionAuthenticator
    def self.call(request)
      public_id = request.headers["X-DiscussionBridge-Connection"]
      secret = request.headers["X-DiscussionBridge-Secret"]
      return unless public_id.is_a?(String) &&
        AdapterRequestBoundary::CONNECTION_ID_PATTERN.match?(public_id)

      connection = DiscussionBridgeContentConnection.find_by(public_id: public_id, enabled: true)
      return unless connection&.authenticate_secret?(secret)

      adapter_id = request.headers["X-DiscussionBridge-Adapter"]
      adapter_version = request.headers["X-DiscussionBridge-Adapter-Version"]
      if adapter_id.present? || adapter_version.present?
        return unless valid_adapter_value?(adapter_id) && valid_adapter_value?(adapter_version)
      end

      # Authentication is read-only. Presence is recorded only after an accepted
      # transaction, never as a side effect of a rejected request.
      connection
    end

    def self.valid_adapter_value?(value)
      return false unless value.is_a?(String)
      utf8 = value.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? && utf8.present? && utf8.bytesize <= 100 && !utf8.match?(/[\x00-\x1f\x7f]/)
    end

    private_class_method :valid_adapter_value?
  end
end
