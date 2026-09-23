# frozen_string_literal: true

require "digest"

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
      raise Discourse::InvalidAccess unless DiscussionBridge::OperatorServiceAccess.mutate?(@user)

      record = DiscussionBridgeBridgeRecord.find_by!(
        resource_id: @resource_id,
        direction: "from_discourse",
      )

      DiscussionBridgeBridgeRecord.transaction do
        connection = record.content_bindings.find_by!(role: "presentation", state: "active").content_connection
        connection.lock!
        binding = record.content_bindings.lock.find_by!(role: "presentation", state: "active")
        canonical = CanonicalSource.call(
          connection_id: connection.public_id,
          source_url: @canonical_url,
        )
        raise ArgumentError, "origin is outside connection scope" unless
          connection.allows_origin?(canonical.source_url)
        if binding.native_materialization && binding.canonical_url != canonical.source_url
          raise ArgumentError, "native publication URL change requires an explicit migration and verified redirect"
        end

        canonical_url_digest = Digest::SHA256.hexdigest(
          "#{connection.public_id}\n#{canonical.source_url}",
        )
        raise ArgumentError, "presentation URL is reserved by migration history" if
          binding.canonical_url != canonical.source_url &&
            (DiscussionBridgePresentationUrlHistory.where(old_canonical_url_digest: canonical_url_digest).exists? ||
             DiscussionBridgeSourceUrlHistory.where(old_canonical_url_digest: canonical_url_digest).exists?)
        conflict = DiscussionBridgeContentBinding.where(
          canonical_url_digest: canonical_url_digest,
        ).where.not(id: binding.id).exists?
        raise ArgumentError, "presentation URL is already bound" if conflict

        unless binding.canonical_url == canonical.source_url
          binding.update!(
            canonical_url: canonical.source_url,
            canonical_url_digest: canonical_url_digest,
          )
          record.touch
        end
      end

      record.reload
    end
  end
end
