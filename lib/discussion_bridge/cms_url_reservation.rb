# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class CmsUrlReservation
    BINDING_BATCH_SIZE = 100

    def self.collision_key(url)
      CmsProtocol.validate!("Url", url)
      CmsProtocol.url_key(url)
    end

    def self.collision_digest(url)
      Digest::SHA256.hexdigest(collision_key(url))
    end

    # Shared transaction-level lock for all current mapping/binding writers.
    def self.with_locks(urls)
      # Retain every original key/lock. Also serialize domain aliases against
      # their comparison key, without rewriting stored reservation digests.
      keys =
        urls
          .flat_map do |url|
            [collision_key(url), CmsProtocol.url_authority(url).comparison_key]
          end
          .uniq
          .sort
      DiscussionBridgeCmsUrlReservation.transaction do
        keys.each do |key|
          unsigned =
            Digest::SHA256.hexdigest("discussionbridge-cms-url-1\n#{key}")[
              0,
              16
            ].to_i(16)
          signed = unsigned >= (1 << 63) ? unsigned - (1 << 64) : unsigned
          DB.exec("SELECT pg_advisory_xact_lock(:key::bigint)", key: signed)
        end
        yield
      end
    end

    def reserve_active!(mapping)
      binding = mapping.content_binding
      url = binding.canonical_url
      self
        .class
        .with_locks([url]) do
          key = self.class.collision_key(url)
          digest = self.class.collision_digest(url)
          row =
            DiscussionBridgeCmsUrlReservation.lock.find_by(
              collision_key_sha256: digest
            )
          if row
            unless row.cms_mapping_id == mapping.id && row.state == "active" &&
                     row.canonical_url == url &&
                     self.class.collision_key(row.canonical_url) == key
              CmsProtocol.reject!("url_collision")
            end
          end
          reject_binding_collision!(key, allowed_binding_id: binding.id)
          row ||
            DiscussionBridgeCmsUrlReservation.create!(
              cms_mapping: mapping,
              canonical_url: url,
              collision_key_sha256: digest,
              state: "active"
            )
        end
    end

    private

    def reject_binding_collision!(key, allowed_binding_id:)
      comparison = CmsProtocol.url_authority(key).comparison_key
      # A retired/prepared spelling may no longer be on the active binding.
      # Its reservation still excludes an equivalent domain alias. The exact
      # digest's ownership/state is checked separately by each native writer.
      DiscussionBridgeCmsUrlReservation
        .where.not(collision_key_sha256: Digest::SHA256.hexdigest(key))
        .find_each(batch_size: BINDING_BATCH_SIZE) do |reservation|
          candidate = comparison_key(reservation.canonical_url)
          CmsProtocol.reject!("url_collision") if candidate == comparison
        end
      # Preserve protected HTTPS key semantics, including exact escaped path and
      # query bytes. Read all existing active/prepared/historical bindings in
      # bounded batches, preserving exact current HTTPS collision-key bytes.
      DiscussionBridgeContentBinding
        .where.not(id: allowed_binding_id)
        .find_each(batch_size: BINDING_BATCH_SIZE) do |binding|
          candidate =
            begin
              CmsProtocol.url_authority(binding.canonical_url).comparison_key
            rescue CmsProtocol::Error
              nil # Outside the protected CMS HTTPS collision-key space.
            end
          CmsProtocol.reject!("url_collision") if candidate == comparison
        end
    end

    def comparison_key(url)
      CmsProtocol.url_authority(url).comparison_key
    rescue CmsProtocol::Error
      nil # Invalid historical URLs cannot establish new URL authority.
    end
  end
end
