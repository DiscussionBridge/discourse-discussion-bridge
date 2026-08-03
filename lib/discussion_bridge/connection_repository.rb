# frozen_string_literal: true

require "securerandom"

module DiscussionBridge
  class ConnectionRepository
    Reservation = Data.define(:state, :topic_id, :record_id, :token)
    Commit = Data.define(:mapping, :creation)

    def reserve!(canonical:, request:, policy:)
      token = SecureRandom.hex(32)
      record =
        DiscussionBridgeConnection.transaction(requires_new: true) do
          DiscussionBridgeConnection.create!(
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
        end
      Reservation.new(state: "reserved", topic_id: nil, record_id: record.id, token: token)
    rescue ActiveRecord::RecordNotUnique
      existing_reservation(canonical, request, policy)
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record.errors.details[:source_identity_digest]&.any? { |detail| detail[:error] == :taken }

      existing_reservation(canonical, request, policy)
    end

    def existing_reservation(canonical, request, policy)
      reservation = nil
      DiscussionBridgeConnection.transaction(requires_new: true) do
        existing = DiscussionBridgeConnection.lock.find_by!(source_identity_digest: canonical.identity_digest)
        if existing.state == "complete" && existing.canonical_source_url == canonical.source_url
          reservation = Reservation.new(state: "complete", topic_id: existing.topic_id, record_id: existing.id, token: nil)
        elsif existing.retry_authorized_at.present? && existing.canonical_source_url == canonical.source_url
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
          reservation = Reservation.new(state: "reserved", topic_id: nil, record_id: existing.id, token: token)
        else
          reservation = Reservation.new(state: "conflict", topic_id: existing.topic_id, record_id: existing.id, token: nil)
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

    def verify_reservation!(mapping, reservation)
      return if mapping.state == "reserved" && mapping.reservation_token == reservation.token

      raise DiscussionBridgeConnection::IdentityConflict
    end
  end
end
