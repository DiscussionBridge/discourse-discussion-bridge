# frozen_string_literal: true

module DiscussionBridge
  # Native administration only. Evidence is the authorized operator's recorded
  # verification, not an adapter assertion or an invented remote health probe.
  module PublicationRetry
    FIELDS = %w[failure_id retry_generation correction_evidence].freeze
    EVIDENCE_FIELDS = %w[error_code summary verification reference verified_at].freeze

    def self.actor!(actor)
      DestinationPolicy.fail_with("policy_denied") unless actor&.admin? && actor.active? && !actor.staged? &&
        !actor.suspended? && !actor.silenced? && actor.id != Discourse::SYSTEM_USER_ID
    end

    def self.validate!(request)
      DestinationPolicy.object!(request, FIELDS)
      DestinationPolicy.fail_with unless request["failure_id"].is_a?(Integer) && request["failure_id"].between?(1, BridgeRecordRequest::MAX_SAFE_INTEGER) &&
        request["retry_generation"].is_a?(Integer) && request["retry_generation"].between?(0, 2_147_483_646)
      evidence = request["correction_evidence"]
      DestinationPolicy.object!(evidence, EVIDENCE_FIELDS)
      DestinationPolicy.fail_with if (PublicationFailure::RETRYABLE + PublicationFailure::TERMINAL).exclude?(evidence["error_code"])
      %w[summary verification reference].each do |field|
        DestinationPolicy.string!(evidence[field], field == "reference" ? 1024 : 2048)
        DestinationPolicy.fail_with if PublicationFailure::SECRET_PATTERN.match?(evidence[field])
      end
      # An evidence reference is recorded, never fetched (no SSRF/credential
      # forwarding). It must identify the operator's actual verification record.
      PublicationAcknowledgement.canonical!(evidence.fetch("reference"))
      BridgeRecordRequest.timestamp!(evidence["verified_at"])
    rescue ArgumentError
      DestinationPolicy.fail_with
    end

    def self.evidence_digest(request)
      NativeSourceRevisionCapture.fingerprint(request.fetch("correction_evidence").except("verified_at"))
    end

    def self.verify_receipt!(receipt)
      PublicationFailure.verify!(receipt.publication_failure)
      DestinationPolicy.fail_with("reconciliation_required") unless receipt.receipt_digest
      value = receipt.request
      issued = receipt.publication_failure.work_issue
      response = { "work_id" => receipt.publication_work.public_id, "retry_generation" => receipt.retry_generation,
        "attempt_count" => 1, "state" => "available" }
      DestinationPolicy.fail_with("integrity_failed") unless receipt.publication_failure.work_issue.publication_work_id == receipt.publication_work_id &&
        issued.work["retry_generation"] == receipt.prior_generation && receipt.retry_generation == receipt.prior_generation + 1 &&
        value["failure_id"] == receipt.publication_failure_id && value["retry_generation"] == receipt.prior_generation &&
        value.fetch("correction_evidence")["error_code"] == receipt.publication_failure.request["error_code"] &&
        receipt.receipt_digest == NativeSourceRevisionCapture.fingerprint(receipt_context(receipt)) &&
        receipt.request_digest == NativeSourceRevisionCapture.fingerprint(value) && receipt.evidence_digest == evidence_digest(value) &&
        receipt.response == response && receipt.response_digest == NativeSourceRevisionCapture.fingerprint(response)
      verified = BridgeRecordRequest.timestamp!(value.fetch("correction_evidence").fetch("verified_at"))
      performed = BridgeRecordRequest.timestamp!(receipt.performed_at_raw)
      DestinationPolicy.fail_with("integrity_failed") if verified <= BridgeRecordRequest.timestamp!(receipt.publication_failure.received_at_raw) ||
        verified > performed || (performed - receipt.performed_at.to_datetime).abs > Rational(1, 86_400_000_000)
    end

    def self.receipt_context(receipt)
      receipt.attributes.slice("publication_work_id", "publication_failure_id", "actor_id", "prior_generation",
        "retry_generation", "request_digest", "evidence_digest", "response_digest", "performed_at_raw")
    end

    def self.accept!(connection:, public_id:, request:, actor:)
      actor!(actor)
      validate!(request)
      connection.with_lock do
        PublicationWork.connection!(connection)
        work = DiscussionBridgePublicationWork.joins(:publication_destination)
          .where(discussion_bridge_publication_destinations: { content_connection_id: connection.id }).find_by!(public_id: public_id)
        destination = work.publication_destination
        destination.lock!
        work.lock!
        PublicationWork.verify!(work)
        DestinationPolicy.fail_with("work_superseded") if work.state == "superseded" || destination.desired_work_id != work.id
        retained = DiscussionBridgePublicationRetry.find_by(publication_work_id: work.id, prior_generation: request.fetch("retry_generation"))
        if retained
          verify_receipt!(retained)
          DestinationPolicy.fail_with("operation_replay_mismatch") unless retained.request == request && retained.actor_id == actor.id
          return retained.response.deep_dup
        end
        DestinationPolicy.fail_with("lease_conflict") unless work.state == "operator_attention" && !destination.active_work_id &&
          work.retry_generation == request.fetch("retry_generation")
        failure = DiscussionBridgePublicationFailure.joins(:work_issue)
          .where(discussion_bridge_work_issues: { publication_work_id: work.id }).order(id: :desc).first!
        PublicationFailure.verify!(failure)
        issued = failure.work_issue
        DestinationPolicy.fail_with("reconciliation_required") unless failure.id == request.fetch("failure_id") &&
          failure.resulting_state == "operator_attention" && issued.work["retry_generation"] == work.retry_generation &&
          issued.work["attempt_count"] == work.attempt_count && issued.work["lease_token"] == work.lease_token
        evidence = request.fetch("correction_evidence")
        now = Time.now.utc
        verified = BridgeRecordRequest.timestamp!(evidence.fetch("verified_at"))
        DestinationPolicy.fail_with unless evidence.fetch("error_code") == failure.request.fetch("error_code") &&
          verified > BridgeRecordRequest.timestamp!(failure.received_at_raw) && verified <= now.to_datetime
        if DiscussionBridgePublicationRetry.where(publication_work_id: work.id, evidence_digest: evidence_digest(request)).exists?
          DestinationPolicy.fail_with("reconciliation_required")
        end
        current_authority!(connection, destination, work)
        generation = work.retry_generation + 1
        result = { "work_id" => work.public_id, "retry_generation" => generation, "attempt_count" => 1, "state" => "available" }
        receipt = DiscussionBridgePublicationRetry.new(publication_work: work, publication_failure: failure, actor: actor,
          prior_generation: work.retry_generation, retry_generation: generation, request: request.deep_dup,
          request_digest: NativeSourceRevisionCapture.fingerprint(request), evidence_digest: evidence_digest(request),
          response: result.deep_dup, response_digest: NativeSourceRevisionCapture.fingerprint(result),
          performed_at: now, performed_at_raw: now.iso8601(9))
        receipt.receipt_digest = NativeSourceRevisionCapture.fingerprint(receipt_context(receipt))
        receipt.save!
        # Clear the failed attempt's ownership, not its append-only history.
        # A static resume stage/binding survives and remains excluded from
        # ordinary native-mutation claims pending its separate recovery path.
        work.update!(state: "available", attempt_count: 1, retry_generation: generation, next_retry_at: nil,
          lease_token: nil, stage_token: nil, worker_id: nil, lease_started_at: nil, lease_expires_at: nil, total_lease_seconds: 0)
        result
      end
    end

    def self.current_authority!(connection, destination, work)
      entry = work.source_inventory_entry
      topic = Topic.with_deleted.lock.find_by(id: entry.topic_id)
      record = entry.bridge_record
      record.lock!
      binding = entry.content_binding
      binding.lock!
      current = DiscussionBridgeDestinationPolicy.current(connection).find_by(destination_policy_id: destination.destination_policy_id)
      DestinationPolicy.fail_with("policy_denied") unless current&.id == work.destination_policy_id
      DestinationPolicy.fail_with("scope_denied") unless PublicationWorkProducer.eligible?(connection, entry, record, binding, topic) &&
        work.context["scope_revision"] == SourceConnectionScope.revision(connection)
      DestinationPolicy.availability!(current.definition, PlatformCatalog.current(connection, current.platform_profile))
    end
  end
end
