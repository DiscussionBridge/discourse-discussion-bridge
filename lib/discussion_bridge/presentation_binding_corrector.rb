# frozen_string_literal: true

module DiscussionBridge
  class PresentationBindingCorrector
    def self.call(user:, resource_id:, canonical_url:)
      new(user: user, resource_id: resource_id, canonical_url: canonical_url).call
    end

    def initialize(user:, resource_id:, canonical_url:)
      @user = user
      @resource_id = resource_id
      @canonical_url = canonical_url
    end

    def call
      raise Discourse::InvalidAccess unless @user&.staff?

      record = DiscussionBridgeBridgeRecord.find_by!(
        resource_id: @resource_id,
        direction: "from_discourse",
      )

      DiscussionBridgeBridgeRecord.transaction do
        binding = record.content_bindings.lock.find_by!(role: "presentation", state: "active")
        connection = binding.content_connection
        canonical = CanonicalSource.call(
          connection_id: connection.public_id,
          source_url: @canonical_url,
        )
        raise ArgumentError, "origin is outside connection scope" unless
          connection.allows_origin?(canonical.source_url)

        unless binding.canonical_url == canonical.source_url
          raise ArgumentError,
                "presentation URL changes require verified migration and native identity confirmation"
        end
      end

      record.reload
    end
  end
end
