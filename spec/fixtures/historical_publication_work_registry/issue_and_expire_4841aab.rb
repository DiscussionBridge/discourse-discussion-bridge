# frozen_string_literal: true

# Exact method bodies extracted from
# lib/discussion_bridge/publication_work_registry.rb at commit
# 4841aab89eee3d0927c43ff01da44eae956aae55 (Git blob
# 00e90703c4cb663125a7bb3b80f51641bd61598e). The wrapper only gives the
# historical methods an isolated executable class for the migration proof.
module DiscussionBridge
  class HistoricalPublicationWorkRegistry4841aab
    Claim = Data.define(:work, :lease_token, :stage_token)

    def initialize(connection:)
      @connection = connection
    end

    def reconcile_expired!(now)
      @connection.publication_works.where(state: "retry_wait").where("next_retry_at <= ?", now).find_each do |work|
        work.with_lock do
          next unless work.state == "retry_wait" && work.next_retry_at&.<=(now)

          work.update!(
            state: "available",
            attempt_count: [work.attempt_count + 1, PublicationWorkProtocol::MAXIMUM_TOTAL_ATTEMPTS].min,
            available_at: now,
            worker_id: nil,
            lease_token_digest: nil,
            stage_token_digest: nil,
            total_lease_seconds: 0,
            leased_at: nil,
            lease_expires_at: nil,
            failure_request_digest: nil,
            failure_response_payload: nil,
          )
        end
      end
      @connection.publication_works.where(state: %w[leased awaiting_deployment awaiting_verification])
        .where("lease_expires_at <= ?", now).find_each do |work|
        work.with_lock do
          next unless %w[leased awaiting_deployment awaiting_verification].include?(work.state) &&
            work.lease_expires_at&.<=(now)

          newer = @connection.publication_works.where(content_binding_id: work.content_binding_id)
            .where.not(id: work.id).where.not(state: %w[acknowledged superseded])
            .where("source_revision_sequence > ? OR created_at > ?", work.source_revision_sequence, work.created_at)
            .exists?
          work.update!(
            state: newer ? "superseded" : "available",
            superseded_at: newer ? now : nil,
            available_at: newer ? work.available_at : now,
            worker_id: nil,
            lease_token_digest: nil,
            stage_token_digest: nil,
            total_lease_seconds: 0,
            leased_at: nil,
            lease_expires_at: nil,
          )
        end
      end
    end

    def claim_one(candidate, worker_id:, lease_seconds:, now:)
      claim = nil
      candidate.with_lock do
        next unless candidate.state == "available" && candidate.resolution_error.nil?
        blocker = @connection.publication_works.where(content_binding_id: candidate.content_binding_id)
          .where(state: %w[leased awaiting_deployment awaiting_verification]).where.not(id: candidate.id).exists?
        next if blocker

        lease_token = PublicationWorkProtocol.token
        stage_token = PublicationWorkProtocol.token
        candidate.update!(
          state: resumed_claim_state(candidate),
          worker_id: worker_id,
          lease_token_digest: PublicationWorkProtocol.token_digest(lease_token),
          stage_token_digest: PublicationWorkProtocol.token_digest(stage_token),
          total_lease_seconds: lease_seconds,
          leased_at: now,
          lease_expires_at: now + lease_seconds.seconds,
        )
        claim = Claim.new(work: candidate, lease_token: lease_token, stage_token: stage_token)
      end
      claim
    end

    def resumed_claim_state(work)
      case work.last_acknowledged_stage
      when nil
        "leased"
      when "synchronized"
        "awaiting_deployment"
      when "deployed"
        "awaiting_verification"
      else
        raise AdapterRequestBoundary::Error, "stage_conflict"
      end
    end
  end
end
