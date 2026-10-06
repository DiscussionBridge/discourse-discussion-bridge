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

    def self.reconcile_record!(record:, connection:)
      new(connection: connection).reconcile_record!(record)
    end

    def self.reconcile_policy_removal!(connection:, previous_authority:)
      new(connection: connection).reconcile_policy_removal!(previous_authority)
    end

    def initialize(connection:)
      @connection = connection
    end

    def reconcile!
      source_records.find_each do |record|
        reconcile_record!(record)
      end
    end

    def reconcile_record!(record)
      return unless source_records.where(id: record.id).exists?
      result = nil
      @connection.with_lock do
        record.lock!
        next if ConnectionCapability.publication_readiness(@connection) == :temporarily_unavailable

        reason = SourceRevisionMaterializer.unavailability_reason(
          record: record,
          connection: @connection,
        )
        if reason
          revoke!(record, reason)
          next
        end

        if active_revocations(record).exists?
          result = restore!(record)
          next
        end

        materialized = SourceRevisionMaterializer.call(record: record, connection: @connection)
        if materialized.reason
          revoke!(record, materialized.reason)
        else
          result = materialized
        end
      end
      result
    end

    def reconcile_policy_removal!(previous_authority)
      previous = previous_authority.deep_stringify_keys
      return unless previous["enabled"] &&
        Array(previous["allowed_directions"]).include?("from_discourse")

      previous_policies = Array(previous["destination_policies"]).map(&:deep_stringify_keys)
      previous_policies.reject! { |policy| ConnectionCapability.pending_catalog_policy?(policy) }
      return if previous_policies.empty?

      current_policies = if @connection.enabled && @connection.allows_direction?("from_discourse")
        Array(@connection.destination_policies).map(&:deep_stringify_keys)
      else
        []
      end
      removed = previous_policies.reject do |policy|
        current_policies.any? { |current| current == policy }
      end
      return if removed.empty?

      source_records.find_each do |record|
        revocation = policy_removed_revocation!(
          record,
          policy_revision: previous.fetch("policy_revision"),
        )
        PublicationWorkRegistry.ensure_policy_withdrawal!(
          record: record,
          connection: @connection,
          revocation: revocation,
          policies: removed,
          policy_revision: previous.fetch("policy_revision"),
        )
        restore!(record) if ConnectionCapability.publication_active?(@connection)
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
      result = nil
      @connection.with_lock do
        record.with_lock do
          current = active_revocations(record).order(source_revision_sequence: :desc).first
          if current&.reason == reason
            result = current
            next
          end

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
          result = revocation
        end
      end
      result
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def policy_removed_revocation!(record, policy_revision:)
      result = nil
      @connection.with_lock do
        record.with_lock do
          current = active_revocations(record).order(source_revision_sequence: :desc).first
          if current&.reason == "policy_removed"
            result = current
            next
          end

          sequence = next_sequence(record)
          revision = "revocation:#{record.resource_id}:#{sequence}"
          revocation = DiscussionBridgeSourceRevocation.create!(
            bridge_record: record,
            content_connection: @connection,
            revocation_id: "dbr_#{SecureRandom.hex(16)}",
            source_revision: revision,
            source_revision_sequence: sequence,
            reason: "policy_removed",
            effective_at: Time.zone.now,
            restorable: true,
            affected_binding_ids: record.content_bindings.where(
              content_connection_id: @connection.id,
              state: "active",
            ).pluck(:binding_id),
            policy_revision: policy_revision,
          )
          record.update!(
            source_revision: revision,
            source_revision_sequence: sequence,
            source_updated_at: revocation.effective_at,
          )
          result = revocation
        end
      end
      result
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def restore!(record)
      active = active_revocations(record).to_a
      return if active.empty?

      materialized = SourceRevisionMaterializer.call(
        record: record,
        connection: @connection,
        force_revision: true,
      )
      if materialized.reason
        revoke!(record, materialized.reason)
        return
      end

      now = Time.zone.now
      DiscussionBridgeSourceRevocation.where(id: active.map(&:id)).update_all(
        restored_at: now,
        updated_at: now,
      )
      materialized
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
