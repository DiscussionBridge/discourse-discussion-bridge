# frozen_string_literal: true

require "digest"

module DiscussionBridge
  module UrlReservation
    def self.digest(connection, canonical_url)
      Digest::SHA256.hexdigest("#{connection.public_id}\n#{canonical_url}")
    end

    def self.ensure_available!(connection:, canonical_url:, binding: nil,
                               allow_owned_retired: false)
      value = digest(connection, canonical_url)
      active = DiscussionBridgeContentBinding.where(canonical_url_digest: value)
      active = active.where.not(id: binding.id) if binding
      raise AdapterRequestBoundary::Error, "destination_collision" if active.exists?

      [DiscussionBridgeSourceUrlHistory, DiscussionBridgePresentationUrlHistory].each do |model|
        reserved = model.where(old_canonical_url_digest: value)
        reserved = reserved.where.not(content_binding_id: binding.id) if
          binding && allow_owned_retired
        raise AdapterRequestBoundary::Error, "url_retired" if reserved.exists?
      end

      value
    end
  end
end
