# frozen_string_literal: true

module DiscussionBridge
  class CreateOrResolve
    Result = Data.define(
      :outcome,
      :reason,
      :topic_id,
      :requested,
      :effective,
      :correlation_id,
    )

    def self.call(request:, policy:, repository:, topic_creator:, audit_writer:)
      unless policy.allowed
        result = result_for("rejected", policy.reason, request, policy)
        audit_writer.call(result)
        return result
      end

      canonical = CanonicalSource.call(connection_id: request.fetch(:connection_id), source_url: request.fetch(:source_url))
      reservation = repository.reserve!(canonical: canonical, request: request, policy: policy)
      if reservation.state == "complete"
        result = result_for("resolved", "existing_mapping", request, policy, reservation.topic_id)
        audit_writer.call(result)
        return result
      end
      if reservation.state != "reserved"
        result = result_for(
          "reconciliation_required",
          (reservation.respond_to?(:reason) && reservation.reason) || "identity_conflict",
          request,
          policy,
        )
        audit_writer.call(result)
        return result
      end

      result = nil
      commit = repository.commit!(
        reservation: reservation,
        after_mapping: lambda do |mapping, _creation|
          result = result_for("created", "durable_mapping_created", request, policy, mapping.topic_id)
          audit_writer.call(result)
        end,
      ) do
        topic_creator.call(request: request, policy: policy)
      end
      begin
        topic_creator.after_commit(commit.creation)
      rescue StandardError => error
        Rails.logger.error("DiscussionBridge post-commit topic jobs failed: #{error.class}")
      end
      result
    rescue DiscussionBridgeConnection::IdentityConflict
      result = result_for("reconciliation_required", "identity_conflict", request, policy)
      audit_writer.call(result)
      result
    rescue StandardError => error
      repository.fail!(reservation: reservation, error: error) if defined?(reservation) && reservation&.state == "reserved"
      raise
    end

    def self.result_for(outcome, reason, request, policy, topic_id = nil)
      Result.new(
        outcome: outcome,
        reason: reason,
        topic_id: topic_id,
        requested: AuditState.requested(request),
        effective: AuditState.effective(policy),
        correlation_id: request[:correlation_id],
      )
    end
    private_class_method :result_for
  end
end
