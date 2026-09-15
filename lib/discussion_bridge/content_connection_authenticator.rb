# frozen_string_literal: true

module DiscussionBridge
  class ContentConnectionAuthenticator
    def self.call(request)
      public_id = request.headers["X-DiscussionBridge-Connection"]
      secret = request.headers["X-DiscussionBridge-Secret"]
      return unless public_id.is_a?(String) && public_id.bytesize <= 64

      connection = DiscussionBridgeContentConnection.find_by(public_id: public_id, enabled: true)
      return unless connection&.authenticate_secret?(secret)

      adapter_id = request.headers["X-DiscussionBridge-Adapter"]
      adapter_version = request.headers["X-DiscussionBridge-Adapter-Version"]
      if adapter_id.present? || adapter_version.present?
        return unless valid_adapter_value?(adapter_id) && valid_adapter_value?(adapter_version)
      end

      attributes = { last_seen_at: Time.zone.now, updated_at: Time.zone.now }
      attributes[:adapter_id] = adapter_id if adapter_id.present?
      attributes[:adapter_version] = adapter_version if adapter_version.present?
      connection.update_columns(**attributes)
      connection
    end

    def self.valid_adapter_value?(value)
      value.is_a?(String) && value.present? && value.bytesize <= 100 && !value.match?(/[\x00-\x1f\x7f]/)
    end

    private_class_method :valid_adapter_value?
  end
end
