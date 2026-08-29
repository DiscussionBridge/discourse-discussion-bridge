# frozen_string_literal: true

require "securerandom"

module DiscussionBridge
  class ConnectionRepository
    Reservation = Data.define(:state, :topic_id, :record_id, :token, :reason)
    Commit = Data.define(:mapping, :creation)

    def reserve!(canonical:, request:, policy:)
      token = SecureRandom.hex(32)
      reservation = nil
      DiscussionBridgeConnection.transaction(requires_new: true) do
        matches = locked_identity_matches(canonical)
        reservation =
          if matches.length > 1
            conflict_reservation(matches.first, "legacy_identity_collision")
          elsif matches.one?
            existing = matches.first
            migrate_legacy_identity!(existing, canonical)
            reservation_for_existing(existing, canonical, request, policy)
          else
            record = DiscussionBridgeConnection.create!(
              connection_id: canonical.connection_id,
              canonical_source_url: canonical.source_url,
              source_identity_digest: canonical.identity_digest,
              state: "reserved",
              reservation_token: token,
              effective_actor_id: policy.effective_actor_id,
              lane: request[:lane],
              requested_visibility: request.fetch(:visibility, "unlisted"),
              effective_visibility: policy.effective_visibility,
              requested_state: AuditState.requested(request),
              effective_state: AuditState.effective(policy),
            )
            Reservation.new(state: "reserved", topic_id: nil, record_id: record.id, token: token, reason: nil)
          end
      end
      reservation
    rescue ActiveRecord::RecordNotUnique
      existing_reservation(canonical, request, policy)
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record.errors.details[:source_identity_digest]&.any? { |detail| detail[:error] == :taken }

      existing_reservation(canonical, request, policy)
    end

    def existing_reservation(canonical, request, policy)
      reservation = nil
      DiscussionBridgeConnection.transaction(requires_new: true) do
        matches = locked_identity_matches(canonical)
        if matches.length > 1
          reservation = conflict_reservation(matches.first, "legacy_identity_collision")
        else
          existing = matches.first
          raise DiscussionBridgeConnection::IdentityConflict unless existing
          migrate_legacy_identity!(existing, canonical)
          reservation = reservation_for_existing(existing, canonical, request, policy)
        end
      end
      reservation
    end

    def commit!(reservation:, after_mapping: nil)
      creation = nil
      mapping = nil
      DiscussionBridgeConnection.transaction do
        mapping = DiscussionBridgeConnection.lock.find(reservation.record_id)
        verify_reservation!(mapping, reservation)
        creation = yield
        mapping.update!(
          topic_id: creation.topic.id,
          state: "complete",
          reservation_token: nil,
        )
        after_mapping&.call(mapping, creation)
      end
      Commit.new(mapping: mapping, creation: creation)
    end

    def fail!(reservation:, error:)
      DiscussionBridgeConnection
        .where(id: reservation.record_id, state: "reserved", reservation_token: reservation.token)
        .update_all(state: "failed", reservation_token: nil, updated_at: Time.zone.now)
      Rails.logger.warn("DiscussionBridge reservation failed: #{error.class}")
    end

    private

    private :existing_reservation

    def locked_identity_matches(canonical)
      legacy = CanonicalSource.legacy_index_alias(canonical)
      digests = [canonical.identity_digest, legacy&.identity_digest].compact
      DiscussionBridgeConnection.lock.where(source_identity_digest: digests).order(:id).to_a
    end

    def migrate_legacy_identity!(existing, canonical)
      return if existing.source_identity_digest == canonical.identity_digest

      legacy = CanonicalSource.legacy_index_alias(canonical)
      unless legacy && existing.connection_id == legacy.connection_id &&
          existing.canonical_source_url == legacy.source_url &&
          existing.source_identity_digest == legacy.identity_digest
        raise DiscussionBridgeConnection::IdentityConflict
      end

      existing.update!(
        canonical_source_url: canonical.source_url,
        source_identity_digest: canonical.identity_digest,
      )
    end

    def reservation_for_existing(existing, canonical, request, policy)
      if existing.state == "complete" && existing.canonical_source_url == canonical.source_url
        integrity = ExistingMappingIntegrity.call(mapping: existing, policy: policy, request: request)
        return Reservation.new(
          state: integrity.usable? ? "complete" : "conflict",
          topic_id: integrity.usable? ? existing.topic_id : nil,
          record_id: existing.id,
          token: nil,
          reason: integrity.usable? ? nil : integrity.reason,
        )
      end

      if existing.retry_authorized_at.present?
        token = SecureRandom.hex(32)
        existing.update!(
          state: "reserved",
          reservation_token: token,
          effective_actor_id: policy.effective_actor_id,
          lane: request[:lane],
          requested_visibility: request.fetch(:visibility, "unlisted"),
          effective_visibility: policy.effective_visibility,
          requested_state: AuditState.requested(request),
          effective_state: AuditState.effective(policy),
          retry_authorized_at: nil,
          retry_authorized_by_id: nil,
        )
        return Reservation.new(
          state: "reserved",
          topic_id: nil,
          record_id: existing.id,
          token: token,
          reason: nil,
        )
      end

      conflict_reservation(existing, "identity_conflict")
    end

    def conflict_reservation(existing, reason)
      Reservation.new(
        state: "conflict",
        topic_id: nil,
        record_id: existing.id,
        token: nil,
        reason: reason,
      )
    end

    def verify_reservation!(mapping, reservation)
      return if mapping.state == "reserved" && mapping.reservation_token == reservation.token

      raise DiscussionBridgeConnection::IdentityConflict
    end
  end
end
