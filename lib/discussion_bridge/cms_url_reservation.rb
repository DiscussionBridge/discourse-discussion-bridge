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
      keys = urls.map { |url| collision_key(url) }.uniq.sort
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
      # Preserve protected HTTPS key semantics, including exact escaped path and
      # query bytes. Read all existing active/prepared/historical bindings in
      # bounded batches, preserving exact current HTTPS collision-key bytes.
      DiscussionBridgeContentBinding
        .where.not(id: allowed_binding_id)
        .find_each(batch_size: BINDING_BATCH_SIZE) do |binding|
          candidate =
            begin
              CmsProtocol.url_key(binding.canonical_url)
            rescue CmsProtocol::Error
              nil # Outside the protected CMS HTTPS collision-key space.
            end
          CmsProtocol.reject!("url_collision") if candidate == key
        end
    end
  end
end
