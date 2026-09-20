# frozen_string_literal: true

module DiscussionBridge
  class ContentConnectionAuthenticator
    def self.call(request, identity: :claim)
      public_id = request.headers["X-DiscussionBridge-Connection"]
      secret = request.headers["X-DiscussionBridge-Secret"]
      return unless public_id.is_a?(String) && public_id.bytesize <= 64

      connection = DiscussionBridgeContentConnection.find_by(public_id: public_id, enabled: true)
      return unless connection&.authenticate_secret?(secret)

      adapter_id, adapter_version = adapter_identity(request)
      return unless adapter_id

      connection.with_lock do
        connection.reload
        case identity
        when :catalog
          return unless connection.platform_catalog_revision.present? &&
            connection.platform_catalog_adapter_id == adapter_id &&
            connection.platform_catalog_adapter_version == adapter_version
        when :claim
          if connection.adapter_id.present? || connection.adapter_version.present?
            return unless connection.adapter_id == adapter_id
            if connection.platform_catalog_revision.blank?
              connection.adapter_version = adapter_version
            end
          else
            connection.adapter_id = adapter_id
            connection.adapter_version = adapter_version
          end
        when :credential_only
          # The catalog update binds identity atomically with the catalog bytes.
        else
          raise ArgumentError, "invalid adapter identity mode"
        end
        connection.last_seen_at = Time.zone.now
        connection.save! if connection.changed?
      end
      connection
    end

    def self.adapter_identity(request)
      adapter_id = request.headers["X-DiscussionBridge-Adapter"]
      adapter_version = request.headers["X-DiscussionBridge-Adapter-Version"]
      return unless valid_adapter_value?(adapter_id) && valid_adapter_value?(adapter_version)

      [adapter_id, adapter_version]
    end

    def self.valid_adapter_value?(value)
      value.is_a?(String) && value.present? && value.bytesize <= 100 && !value.match?(/[\x00-\x1f\x7f]/)
    end

    private_class_method :valid_adapter_value?
  end
end
