# frozen_string_literal: true

module DiscussionBridge
  class ContentConnectionAuthenticator
    def self.call(request, allow_disabled: false)
      public_id = request.headers[AdapterRequestBoundary::CONNECTION_HEADER]
      secret = request.headers[AdapterRequestBoundary::SECRET_HEADER]
      return unless public_id.is_a?(String) && AdapterRequestBoundary::CONNECTION_ID_PATTERN.match?(public_id)

      connection = DiscussionBridgeContentConnection.find_by(public_id: public_id)
      return unless connection
      return unless connection.enabled || allow_disabled
      return unless connection.authenticate_secret?(secret)

      adapter_id = request.headers["X-DiscussionBridge-Adapter"]
      adapter_version = request.headers["X-DiscussionBridge-Adapter-Version"]
      if connection.enabled
        attributes = { last_seen_at: Time.zone.now, updated_at: Time.zone.now }
        if valid_adapter_value?(adapter_id) && valid_adapter_value?(adapter_version)
          attributes[:adapter_id] = adapter_id
          attributes[:adapter_version] = adapter_version
        end
        connection.update_columns(**attributes)
      end
      connection
    end

    def self.valid_adapter_value?(value)
      value.is_a?(String) && value.present? && value.bytesize <= 100 && !value.match?(/[\x00-\x1f\x7f]/)
    end

    private_class_method :valid_adapter_value?
  end
end
