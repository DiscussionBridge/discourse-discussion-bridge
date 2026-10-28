# frozen_string_literal: true

module DiscussionBridge
  # Validate authoritative receiver bindings. The native adapter owns receipt
  # inspection and anonymous public verification; opaque hashes alone do not
  # establish independent receiver observation of those native systems.
  module CmsUrlMoveProof
    def self.urls!(old_url, new_url)
      CmsProtocol.validate!("Url", old_url)
      CmsProtocol.validate!("Url", new_url)
      old_key = CmsProtocol.url_key(old_url)
      new_key = CmsProtocol.url_key(new_url)
      old = URI(old_key)
      proposed = URI(new_key)
      unless old_key != new_key && [old.scheme, old.host, old.port] == [proposed.scheme, proposed.host, proposed.port]
        CmsProtocol.reject!("identity_conflict")
      end
    end

    def self.checked_at!(verification, prepared_at, now)
      checked = Time.iso8601(verification.fetch("checked_at"))
      unless checked >= prepared_at && checked <= now + CmsWorkCoordinator::LEASE_SECONDS
        CmsProtocol.reject!("invalid_field")
      end
    end

    def self.presentation!(mapping, work, move, input, now)
      ownership = input.fetch("ownership")
      proof = input.fetch("verification")
      binding = mapping.content_binding
      unless ownership.fetch("resource_id") == binding.bridge_record.resource_id &&
          ownership.fetch("external_id") == binding.external_id &&
          ownership.fetch("native_id") == mapping.destination_native_id &&
          ownership.fetch("canonical_url") == move.new_url &&
          ownership.fetch("source_revision") == work.source_revision &&
          proof.fetch("url") == move.new_url && proof.fetch("native_id") == mapping.destination_native_id
        CmsProtocol.reject!("native_ownership_conflict")
      end
      unless proof.fetch("source_revision") == work.source_revision
        CmsProtocol.reject!("revision_conflict")
      end
      unless proof.fetch("source_content_sha256") == work.source_snapshot.fetch("content_sha256")
        CmsProtocol.reject!("content_hash_mismatch")
      end
      CmsWorkCoordinator.new(nil).send(:representation!, work, proof.fetch("representation"))
      checked_at!(proof, move.prepared_at, now)
    end
  end
end
