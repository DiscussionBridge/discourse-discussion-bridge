# frozen_string_literal: true

module DiscussionBridge
  # Existing global HTTPS collision keys/advisory locks, now with an explicit
  # To source-binding owner as well as the existing From mapping owner.
  class CmsMoveReservation
    def self.owner(binding, mapping = nil)
      mapping ? { cms_mapping_id: mapping.id, content_binding_id: nil } :
        { cms_mapping_id: nil, content_binding_id: binding.id }
    end

    def self.reserve!(binding, url, state:, mapping: nil)
      key = CmsUrlReservation.collision_key(url)
      digest = CmsUrlReservation.collision_digest(url)
      owner = owner(binding, mapping)
      row = DiscussionBridgeCmsUrlReservation.lock.find_by(collision_key_sha256: digest)
      if row && (owner.any? { |field, value| row.public_send(field) != value } ||
           row.canonical_url != url || row.state != state)
        CmsProtocol.reject!("url_collision")
      end
      CmsUrlReservation.new.send(:reject_binding_collision!, key, allowed_binding_id: binding.id)
      row || DiscussionBridgeCmsUrlReservation.create!(**owner, canonical_url: url,
        collision_key_sha256: digest, state: state)
    end

    def self.row!(binding, url, state:, mapping: nil)
      row = DiscussionBridgeCmsUrlReservation.lock.find_by(
        **owner(binding, mapping), collision_key_sha256: CmsUrlReservation.collision_digest(url),
      )
      unless row && row.canonical_url == url && row.state == state
        CmsProtocol.reject!("url_collision")
      end
      row
    end

    def self.commit!(binding, move, mapping: nil)
      row!(binding, move.old_url, state: "active", mapping: mapping).update!(state: "retired")
      row!(binding, move.new_url, state: "prepared", mapping: mapping).update!(state: "active")
      binding.update!(canonical_url: move.new_url,
        canonical_url_digest: Digest::SHA256.hexdigest("#{binding.content_connection.public_id}\n#{move.new_url}"))
      DiscussionBridgeCmsUrlHistoryEntry.create!(**owner(binding, mapping), url: move.old_url,
        retired_at: Time.current, move_id: move.move_id, created_at: Time.current)
    end

    def self.release!(binding, move, mapping: nil)
      row!(binding, move.old_url, state: "active", mapping: mapping)
      row!(binding, move.new_url, state: "prepared", mapping: mapping).destroy!
    end
  end
end
