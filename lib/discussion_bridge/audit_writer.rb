# frozen_string_literal: true

module DiscussionBridge
  class AuditWriter
    def initialize(request:)
      @request = request
    end

    def call(result)
      canonical = CanonicalSource.call(
        connection_id: @request.fetch(:connection_id),
        source_url: @request.fetch(:source_url),
      )
      DiscussionBridgeAuditEvent.create!(
        correlation_id: result.correlation_id,
        connection_id: canonical.connection_id,
        adapter_id: @request[:adapter_id],
        source_identity_digest: canonical.identity_digest,
        topic_id: result.topic_id,
        effective_actor_id: result.effective["actor_id"],
        outcome: result.outcome,
        reason: result.reason,
        requested_state: result.requested,
        effective_state: result.effective,
      )
    end
  end
end
