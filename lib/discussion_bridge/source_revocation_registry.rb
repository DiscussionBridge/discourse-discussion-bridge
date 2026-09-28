# frozen_string_literal: true

module DiscussionBridge
  class SourceRevocationRegistry
    def self.reconcile!(connection:)
      new(connection: connection).reconcile!
    end

    def self.scope(connection:)
      DiscussionBridgeSourceRevocation.where(content_connection_id: connection.id)
        .order(:id)
    end

    def initialize(connection:)
      @connection = connection
    end

    def reconcile!
      source_records.find_each do |record|
        reason = SourceRevisionMaterializer.unavailability_reason(
          record: record,
          connection: @connection,
        )
        reason ? revoke!(record, reason) : restore!(record)
      end
    end

    private

    def source_records
      DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(direction: "from_discourse")
        .where(
          discussion_bridge_content_bindings: {
            content_connection_id: @connection.id,
            role: "presentation",
            state: "active",
          },
        )
        .distinct
    end

    def revoke!(record, reason)
      record.with_lock do
        current = active_revocations(record).order(source_revision_sequence: :desc).first
        return current if current&.reason == reason

        sequence = next_sequence(record)
        revision = "revocation:#{record.resource_id}:#{sequence}"
        revocation = DiscussionBridgeSourceRevocation.create!(
          bridge_record: record,
          content_connection: @connection,
          revocation_id: "dbr_#{SecureRandom.hex(16)}",
          source_revision: revision,
          source_revision_sequence: sequence,
          reason: reason,
          effective_at: Time.zone.now,
          restorable: true,
          affected_binding_ids: record.content_bindings.where(
            content_connection_id: @connection.id,
            state: "active",
          ).pluck(:binding_id),
          policy_revision: @connection.policy_revision,
        )
        record.update!(
          source_revision: revision,
          source_revision_sequence: sequence,
          source_updated_at: revocation.effective_at,
        )
        PublicationWorkRegistry.ensure_revocation!(
          record: record,
          connection: @connection,
          revocation: revocation,
        )
        revocation
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def restore!(record)
      active = active_revocations(record).to_a
      return if active.empty?

      SourceRevisionMaterializer.call(
        record: record,
        connection: @connection,
        force_revision: true,
      )
      now = Time.zone.now
      DiscussionBridgeSourceRevocation.where(id: active.map(&:id)).update_all(
        restored_at: now,
        updated_at: now,
      )
    end

    def active_revocations(record)
      record.source_revocations.where(content_connection_id: @connection.id, restored_at: nil)
    end

    def next_sequence(record)
      [
        record.source_revision_sequence.to_i,
        record.source_revisions.maximum(:source_revision_sequence).to_i,
        record.source_revocations.maximum(:source_revision_sequence).to_i,
      ].max + 1
    end
  end
end
