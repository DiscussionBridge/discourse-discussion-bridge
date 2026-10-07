# frozen_string_literal: true

module DiscussionBridge
  module PublicationFailure
    FIELDS = %w[lease_token error_code error_detail failed_at correlation_id].freeze
    RETRYABLE = %w[transport_timeout source_unavailable destination_unavailable rate_limited build_failed deploy_failed public_verification_failed internal_error].freeze
    TERMINAL = %w[authentication_failed scope_denied validation_failed content_unsupported identity_conflict destination_collision reconciliation_required operator_action_required].freeze
    BACKOFF = [60, 300, 900].freeze
    SECRET_PATTERN = /(?:\bBearer\s+\S+|\b(?:api[_ -]?key|password|secret|token)\s*[:=]\s*\S+|-----BEGIN .*PRIVATE KEY-----|\b(?:sk-(?:proj|svcacct|svcac)-|gh[pousr]_|github_pat_|AKIA)[A-Za-z0-9_-]+|https?:\/\/[^\s\/]+:[^\s\/]+@|\b[a-f0-9]{64}\b)/i

    def self.validate!(request, secret:)
      DestinationPolicy.object!(request, FIELDS)
      token = request["lease_token"]
      DestinationPolicy.fail_with unless token.is_a?(String) && /\A[a-f0-9]{64}\z/.match?(token)
      DestinationPolicy.fail_with if (RETRYABLE + TERMINAL).exclude?(request["error_code"])
      detail = request["error_detail"]
      DestinationPolicy.string!(detail, 2048)
      forbidden = [token, secret].compact.reject(&:empty?)
      DestinationPolicy.fail_with if SECRET_PATTERN.match?(detail) || forbidden.any? { |value| detail.include?(value) }
      BridgeRecordRequest.timestamp!(request["failed_at"])
    end

    # Caller owns the authenticated connection transaction. All durable changes
    # and the append-only failure receipt commit together, never from free text.
    def self.accept!(connection, public_id, request, secret:)
      PublicationWork.connection!(connection)
      validate!(request, secret: secret)
      work = DiscussionBridgePublicationWork.joins(:publication_destination)
        .where(discussion_bridge_publication_destinations: { content_connection_id: connection.id }).find_by!(public_id: public_id)
      destination = work.publication_destination
      destination.lock!
      work.lock!
      PublicationWork.verify!(work)
      DestinationPolicy.fail_with("work_superseded") if work.state == "superseded"
      issued = PublicationAcknowledgement.issue!(work, request)
      retained = DiscussionBridgePublicationFailure.find_by(work_issue_id: issued.id)
      if retained
        verify!(retained)
        DestinationPolicy.fail_with("operation_replay_mismatch") unless retained.request == request
        return
      end
      now = Time.now.utc
      DestinationPolicy.fail_with("lease_conflict") unless %w[leased awaiting_deployment awaiting_verification].include?(work.state) &&
        destination.active_work_id == work.id
      DestinationPolicy.fail_with("work_expired") if work.lease_expires_at <= now
      failed = BridgeRecordRequest.timestamp!(request.fetch("failed_at"))
      DestinationPolicy.fail_with if failed < issued.claimed_at.to_datetime || failed > now.to_datetime
      DestinationPolicy.fail_with("reconciliation_required") unless work.attempt_count.between?(1, 4) && work.retry_generation >= 0 &&
        issued.work["attempt_count"] == work.attempt_count && issued.work["retry_generation"] == work.retry_generation
      previous = work.state
      retry_at = if RETRYABLE.include?(request.fetch("error_code")) && work.attempt_count < 4
        now + BACKOFF.fetch(work.attempt_count - 1)
      end
      state = retry_at ? "retry_wait" : "operator_attention"
      failure = DiscussionBridgePublicationFailure.new(work_issue: issued, request: request.deep_dup,
        request_digest: NativeSourceRevisionCapture.fingerprint(request), from_state: previous,
        resulting_state: state, received_at: now, received_at_raw: now.iso8601(9), next_retry_at: retry_at)
      failure.receipt_digest = NativeSourceRevisionCapture.fingerprint(receipt_context(failure))
      failure.save!
      # Static post-sync retries retain their stage and exact binding. Ordinary
      # claims exclude them until the separate stage-recovery acquisition path.
      work.update!(state: state, next_retry_at: retry_at, retry_resume_state: previous == "leased" ? nil : previous)
      destination.update!(active_work: nil)
      nil
    end

    def self.receipt_context(failure)
      failure.attributes.slice("work_issue_id", "request_digest", "from_state", "resulting_state", "received_at_raw")
    end

    def self.verify!(failure)
      issued = failure.work_issue
      count = issued.work["attempt_count"]
      DestinationPolicy.fail_with("integrity_failed") unless count.is_a?(Integer) && count.between?(1, 4)
      DestinationPolicy.fail_with("reconciliation_required") unless failure.received_at_raw
      received = BridgeRecordRequest.timestamp!(failure.received_at_raw)
      expected_retry = if RETRYABLE.include?(failure.request["error_code"]) && count < 4
        failure.received_at + BACKOFF.fetch(count - 1)
      end
      expected_state = expected_retry ? "retry_wait" : "operator_attention"
      DestinationPolicy.fail_with("integrity_failed") unless failure.request_digest == NativeSourceRevisionCapture.fingerprint(failure.request) &&
        failure.receipt_digest == NativeSourceRevisionCapture.fingerprint(receipt_context(failure)) &&
        (received - failure.received_at.to_datetime).abs <= Rational(1, 86_400_000_000) &&
        %w[leased awaiting_deployment awaiting_verification].include?(failure.from_state) &&
        (RETRYABLE + TERMINAL).include?(failure.request["error_code"]) &&
        failure.request["lease_token"] == issued.work["lease_token"] && failure.resulting_state == expected_state &&
        failure.next_retry_at == expected_retry && BridgeRecordRequest.timestamp!(failure.request["failed_at"]) >= issued.claimed_at.to_datetime &&
        BridgeRecordRequest.timestamp!(failure.request["failed_at"]) <= received
    end

    def self.release_due!(connection)
      now = Time.now.utc
      DiscussionBridgePublicationDestination.where(content_connection_id: connection.id).joins(:desired_work)
        .where(discussion_bridge_publication_works: { state: "retry_wait" })
        .where("discussion_bridge_publication_works.next_retry_at <= ?", now)
        .order("discussion_bridge_publication_works.next_retry_at, discussion_bridge_publication_works.id")
        .limit(PublicationWork::MAINTENANCE_LIMIT).each do |destination|
        destination.lock!
        work = destination.desired_work
        work.lock!
        PublicationWork.verify!(work)
        failure = DiscussionBridgePublicationFailure.joins(:work_issue)
          .where(discussion_bridge_work_issues: { publication_work_id: work.id }).order(id: :desc).first!
        verify!(failure)
        DestinationPolicy.fail_with("reconciliation_required") unless work.attempt_count.between?(1, 3) &&
          failure.resulting_state == "retry_wait" && failure.next_retry_at == work.next_retry_at &&
          failure.work_issue.work["attempt_count"] == work.attempt_count && failure.work_issue.work["retry_generation"] == work.retry_generation
        # SQL's microsecond index is only the bounded candidate scan. The exact
        # retained receiver clock decides whether the full delay has elapsed.
        due = BridgeRecordRequest.timestamp!(failure.received_at_raw) + Rational(BACKOFF.fetch(work.attempt_count - 1), 86_400)
        next if now.to_datetime < due
        work.update!(state: "available", attempt_count: work.attempt_count + 1, next_retry_at: nil)
      end
    end
  end
end
