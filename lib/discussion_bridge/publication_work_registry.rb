# frozen_string_literal: true

module DiscussionBridge
  class PublicationWorkRegistry
    Claim = Data.define(:work, :lease_token, :stage_token)

    def self.ensure_revision!(record:, connection:, revision:, action: nil)
      new(connection: connection).ensure_revision!(record: record, revision: revision, action: action)
    end

    def self.ensure_revocation!(record:, connection:, revocation:)
      action = revocation.reason == "operator_hold" ? "hold" : "unpublish"
      new(connection: connection).ensure_work!(
        record: record,
        source_revision_record: nil,
        source_revocation_record: revocation,
        source_revision: revocation.source_revision,
        source_revision_sequence: revocation.source_revision_sequence,
        action: action,
      )
    end

    def self.claim(connection:, worker_id:, maximum_items:, requested_lease_seconds:, correlation_id:)
      new(connection: connection).claim(
        worker_id: worker_id,
        maximum_items: maximum_items,
        requested_lease_seconds: requested_lease_seconds,
        correlation_id: correlation_id,
      )
    end

    def self.renew(connection:, work_id:, lease_token:, requested_lease_seconds:)
      new(connection: connection).renew(
        work_id: work_id,
        lease_token: lease_token,
        requested_lease_seconds: requested_lease_seconds,
      )
    end

    def self.acknowledge(connection:, work_id:, payload:)
      new(connection: connection).acknowledge(work_id: work_id, payload: payload.deep_stringify_keys)
    end

    def self.fail(connection:, work_id:, payload:)
      new(connection: connection).fail(work_id: work_id, payload: payload.deep_stringify_keys)
    end

    def self.manual_retry!(work:, authorized_by:, condition_corrected:)
      raise AdapterRequestBoundary::Error, "policy_denied" unless authorized_by&.staff?
      raise AdapterRequestBoundary::Error, "operator_action_required" unless condition_corrected == true

      work.with_lock do
        raise AdapterRequestBoundary::Error, "stage_conflict" unless work.state == "operator_attention"

        work.update!(
          state: "available",
          attempt_count: 1,
          retry_generation: work.retry_generation + 1,
          available_at: Time.zone.now,
          next_retry_at: nil,
          worker_id: nil,
          lease_token_digest: nil,
          stage_token_digest: nil,
          total_lease_seconds: 0,
          leased_at: nil,
          lease_expires_at: nil,
          failure_code: nil,
          failure_detail: nil,
          failed_at: nil,
          failure_request_digest: nil,
          failure_response_payload: nil,
          resolution_error: nil,
          manual_retry_authorized_by: authorized_by,
          manual_retry_authorized_at: Time.zone.now,
        )
      end
      work
    end

    def initialize(connection:)
      @connection = connection
    end

    def ensure_revision!(record:, revision:, action: nil)
      inferred_action = action || if record.source_revocations.where(
        content_connection_id: @connection.id,
        restored_at: nil,
      ).exists?
        "restore"
      else
        binding = destination_binding(record)
        binding.applied_source_revision.present? ? "update" : "publish"
      end
      ensure_work!(
        record: record,
        source_revision_record: revision,
        source_revocation_record: nil,
        source_revision: revision.source_revision,
        source_revision_sequence: revision.source_revision_sequence,
        action: inferred_action,
      )
    end

    def ensure_work!(record:, source_revision_record:, source_revocation_record:, source_revision:,
                     source_revision_sequence:, action:)
      raise AdapterRequestBoundary::Error, "direction_denied" unless
        @connection.enabled && @connection.allows_direction?("from_discourse")

      policies.each do |policy|
        binding = destination_binding(record)
        attributes, resolution_error = resolved_attributes(
          policy: policy,
          source_revision_record: source_revision_record,
        )
        DiscussionBridgePublicationWork.transaction do
          @connection.lock!
          binding.lock!
          existing = @connection.publication_works.find_by(
            content_binding_id: binding.id,
            source_revision: source_revision,
            policy_revision: @connection.policy_revision,
            destination_policy_id: policy.fetch("destination_policy_id"),
            action: action,
          )
          next existing if existing

          supersede_prior_work!(binding: binding, destination_policy_id: policy.fetch("destination_policy_id"))
          @connection.publication_works.create!(
            {
              bridge_record: record,
              content_binding: binding,
              source_revision_record: source_revision_record,
              source_revocation_record: source_revocation_record,
              action: action,
              state: resolution_error ? "operator_attention" : "available",
              source_revision: source_revision,
              source_revision_sequence: source_revision_sequence,
              policy_revision: @connection.policy_revision,
              destination_policy_id: policy.fetch("destination_policy_id"),
              catalog_revision: policy.fetch("catalog_revision"),
              presentation_mode: policy.fetch("presentation_mode"),
              attempt_count: 1,
              retry_generation: 0,
              available_at: Time.zone.now,
              resolution_error: resolution_error,
            }.merge(attributes),
          )
        end
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def claim(worker_id:, maximum_items:, requested_lease_seconds:, correlation_id:)
      PublicationWorkProtocol.valid_label!(worker_id, PublicationWorkProtocol::WORKER_ID_MAXIMUM_BYTES)
      maximum = maximum_items || PublicationWorkProtocol::DEFAULT_MAXIMUM_ITEMS
      lease_seconds = requested_lease_seconds || PublicationWorkProtocol::DEFAULT_LEASE_SECONDS
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        maximum.is_a?(Integer) && maximum.between?(1, PublicationWorkProtocol::MAXIMUM_ITEMS)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        lease_seconds.is_a?(Integer) && lease_seconds.between?(1, PublicationWorkProtocol::MAXIMUM_REQUESTED_LEASE_SECONDS)

      now = Time.zone.now
      reconcile_expired!(now)
      claims = []
      candidates = @connection.publication_works.where(state: "available", resolution_error: nil)
        .where("available_at IS NULL OR available_at <= ?", now).order(:id).limit(maximum * 4)
      candidates.each do |candidate|
        break if claims.length >= maximum

        claim = claim_one(candidate, worker_id: worker_id, lease_seconds: lease_seconds, now: now)
        claims << claim if claim
      end
      claims.map { |claim| work_payload(claim, correlation_id: correlation_id) }
    end

    def renew(work_id:, lease_token:, requested_lease_seconds:)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        requested_lease_seconds.is_a?(Integer) &&
          requested_lease_seconds.between?(1, PublicationWorkProtocol::MAXIMUM_REQUESTED_LEASE_SECONDS)

      work = find_work(work_id)
      work.with_lock do
        now = Time.zone.now
        raise AdapterRequestBoundary::Error, "work_superseded" if work.state == "superseded"
        raise AdapterRequestBoundary::Error, "work_expired" unless
          work.state == "leased" && work.lease_expires_at&.>(now)
        raise AdapterRequestBoundary::Error, "lease_conflict" unless
          PublicationWorkProtocol.secure_token_match?(work.lease_token_digest, lease_token)
        total = work.total_lease_seconds + requested_lease_seconds
        raise AdapterRequestBoundary::Error, "lease_limit_exceeded" if
          total > PublicationWorkProtocol::MAXIMUM_TOTAL_LEASE_SECONDS

        expires_at = work.lease_expires_at + requested_lease_seconds.seconds
        work.update!(total_lease_seconds: total, lease_expires_at: expires_at)
        {
          work_id: work.work_id,
          lease_expires_at: expires_at.iso8601(6),
          total_lease_seconds: total,
        }
      end
    end

    def acknowledge(work_id:, payload:)
      work = find_work(work_id)
      digest = PublicationWorkProtocol.payload_digest(payload)
      existing = work.acknowledgements.find_by(stage: payload["stage"])
      if existing
        raise AdapterRequestBoundary::Error, "stage_conflict" unless existing.request_digest == digest

        return existing.response_payload.symbolize_keys
      end

      response = nil
      DiscussionBridgePublicationWork.transaction do
        work.lock!
        existing = work.acknowledgements.find_by(stage: payload["stage"])
        if existing
          raise AdapterRequestBoundary::Error, "stage_conflict" unless existing.request_digest == digest
          response = existing.response_payload.symbolize_keys
          next
        end
        validate_acknowledgement!(work, payload)
        response = apply_acknowledgement!(work, payload)
        work.acknowledgements.create!(
          stage: payload.fetch("stage"),
          request_digest: digest,
          request_payload: payload,
          response_payload: response,
        )
      end
      response.symbolize_keys
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def fail(work_id:, payload:)
      work = find_work(work_id)
      digest = PublicationWorkProtocol.payload_digest(payload)
      if work.failure_request_digest.present?
        raise AdapterRequestBoundary::Error, "operation_replay_mismatch" unless
          work.failure_request_digest == digest

        return work.failure_response_payload.symbolize_keys
      end

      response = nil
      work.with_lock do
        if work.failure_request_digest.present?
          raise AdapterRequestBoundary::Error, "operation_replay_mismatch" unless
            work.failure_request_digest == digest
          response = work.failure_response_payload.symbolize_keys
          next
        end
        validate_failure!(work, payload)
        code = payload.fetch("error_code")
        retryable = PublicationWorkProtocol::RETRYABLE_FAILURES.include?(code)
        next_retry_at = if retryable && work.attempt_count < PublicationWorkProtocol::MAXIMUM_TOTAL_ATTEMPTS
          Time.zone.now + PublicationWorkProtocol::RETRY_BACKOFF_SECONDS.fetch(work.attempt_count - 1).seconds
        end
        state = next_retry_at ? "retry_wait" : "operator_attention"
        response = {
          work_id: work.work_id,
          resulting_state: state,
          attempt_count: work.attempt_count,
          next_retry_at: next_retry_at&.iso8601(6),
        }
        work.update!(
          state: state,
          next_retry_at: next_retry_at,
          failure_code: code,
          failure_detail: payload.fetch("error_detail"),
          failed_at: PublicationWorkProtocol.parse_time!(payload.fetch("failed_at")),
          failure_request_digest: digest,
          failure_response_payload: response,
        )
        mark_binding_failure!(work)
      end
      response.symbolize_keys
    end

    private

    def policies
      Array(@connection.destination_policies).map(&:deep_stringify_keys).select do |policy|
        policy["profile"] != "discourse_as_publisher"
      end
    end

    def destination_binding(record)
      binding = record.content_bindings.find_by(
        content_connection_id: @connection.id,
        role: "presentation",
        state: "active",
      )
      raise AdapterRequestBoundary::Error, "reconciliation_required" unless binding

      binding
    end

    def resolved_attributes(policy:, source_revision_record:)
      catalog = PlatformCatalogRegistry.catalog(
        connection: @connection,
        platform_profile: policy.fetch("profile"),
        catalog_revision: policy.fetch("catalog_revision"),
      )
      container_id = policy.dig("container_mapping", "destination")
      container = catalog_item(catalog, "containers", container_id)
      presentation = catalog_item(catalog, "presentation_modes", policy.fetch("presentation_mode"))
      resolution_error = if catalog.nil?
        "catalog_revision_conflict"
      elsif !container&.fetch("available", false) || !presentation&.fetch("available", false)
        "operator_action_required"
      end
      native_limit = policy.fetch("native_limit_policy")
      if source_revision_record && source_revision_record.byte_length > native_limit.fetch("maximum_bytes") &&
          native_limit.fetch("overflow_behavior") != "excerpt_with_read_more"
        resolution_error = "content_unsupported"
      end
      attributes = {
        resolved_container: {
          "id" => container_id,
          "kind" => container&.fetch("kind", nil) || "unresolved",
        },
        resolved_taxonomy: resolved_taxonomy(policy, source_revision_record),
        resolved_author: resolved_author(policy, source_revision_record),
        native_limit_policy: native_limit,
      }
      [attributes, resolution_error]
    end

    def catalog_item(catalog, segment_type, identifier)
      return unless catalog

      catalog.segments.find_by(segment_type: segment_type)&.items&.find do |item|
        item["id"] == identifier
      end
    end

    def resolved_taxonomy(policy, revision)
      return [] unless revision

      source_ids = revision.categories.map { |item| item["source_category_id"] } +
        revision.tags.map { |item| item["source_tag_id"] }
      Array(policy.dig("taxonomy_mapping", "items")).filter_map do |raw|
        item = raw.deep_stringify_keys
        source = item["source"] || item["source_id"]
        destination = item["destination"] || item["destination_id"]
        next if source_ids.exclude?(source) || destination.blank?

        { "source_id" => source, "destination_id" => destination }
      end
    end

    def resolved_author(policy, revision)
      mapping = policy.fetch("author_mapping")
      mode = mapping.fetch("mode")
      destination = mapping["destination_id"]
      if destination.nil? && revision
        source_ids = revision.source_authors.map { |item| item["source_author_id"] }
        match = Array(mapping["items"]).map(&:deep_stringify_keys).find do |item|
          source_ids.include?(item["source"] || item["source_id"])
        end
        destination = match && (match["destination"] || match["destination_id"])
      end
      { "mode" => mode, "destination_id" => destination }
    end

    def supersede_prior_work!(binding:, destination_policy_id:)
      now = Time.zone.now
      @connection.publication_works.where(
        content_binding_id: binding.id,
        destination_policy_id: destination_policy_id,
        state: %w[available retry_wait awaiting_deployment awaiting_verification operator_attention],
      ).update_all(state: "superseded", superseded_at: now, updated_at: now)
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
      @connection.publication_works.where(state: "leased").where("lease_expires_at <= ?", now).find_each do |work|
        work.with_lock do
          next unless work.state == "leased" && work.lease_expires_at&.<=(now)

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
          state: "leased",
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

    def work_payload(claim, correlation_id:)
      work = claim.work
      {
        work_id: work.work_id,
        resource_id: work.bridge_record.resource_id,
        connection_id: @connection.public_id,
        action: work.action,
        source_revision: work.source_revision,
        source_revision_sequence: work.source_revision_sequence,
        policy_revision: work.policy_revision,
        destination_policy_id: work.destination_policy_id,
        catalog_revision: work.catalog_revision,
        presentation_mode: work.presentation_mode,
        resolved_container: work.resolved_container,
        resolved_taxonomy: work.resolved_taxonomy,
        resolved_author: work.resolved_author,
        native_limit_policy: work.native_limit_policy,
        lease_token: claim.lease_token,
        stage_token: claim.stage_token,
        lease_expires_at: work.lease_expires_at.iso8601(6),
        attempt_count: work.attempt_count,
        retry_generation: work.retry_generation,
        correlation_id: correlation_id,
      }
    end

    def validate_acknowledgement!(work, payload)
      raise AdapterRequestBoundary::Error, "work_superseded" if work.state == "superseded"
      raise AdapterRequestBoundary::Error, "stage_conflict" if
        PublicationWorkProtocol::STAGES.exclude?(payload["stage"])
      validate_work_identity!(work, payload)
      PublicationWorkProtocol.validate_destination_binding!(payload.fetch("destination_binding"))
      validate_destination_identity!(work, payload.fetch("destination_binding"))
      raise AdapterRequestBoundary::Error, "lease_conflict" unless
        PublicationWorkProtocol.secure_token_match?(work.lease_token_digest, payload["lease_token"])
      raise AdapterRequestBoundary::Error, "stage_conflict" unless
        PublicationWorkProtocol.secure_token_match?(work.stage_token_digest, payload["stage_token"])
      validate_stage!(work, payload)
      validate_content_disposition!(work, payload.dig("destination_binding", "content_disposition"))
    end

    def validate_work_identity!(work, payload)
      expected = {
        "resource_id" => work.bridge_record.resource_id,
        "source_revision" => work.source_revision,
        "source_revision_sequence" => work.source_revision_sequence,
        "policy_revision" => work.policy_revision,
        "destination_policy_id" => work.destination_policy_id,
        "action" => work.action,
      }
      raise AdapterRequestBoundary::Error, "revision_conflict" unless
        expected.all? { |key, value| payload[key] == value }
    end

    def validate_destination_identity!(work, binding_payload)
      binding = work.content_binding
      expected = {
        "binding_id" => binding.binding_id,
        "external_id" => binding.external_id,
        "canonical_url" => binding.canonical_url,
      }
      raise AdapterRequestBoundary::Error, "identity_conflict" unless
        expected.all? { |key, value| binding_payload[key] == value }
      existing_revision = binding.publication_revision
      raise AdapterRequestBoundary::Error, "identity_conflict" if
        existing_revision.present? && work.last_acknowledged_stage.present? &&
          existing_revision != binding_payload["publication_revision"]
    end

    def validate_stage!(work, payload)
      stage = payload.fetch("stage")
      synchronized_at = PublicationWorkProtocol.parse_time!(payload.fetch("synchronized_at"))
      case stage
      when "synchronized"
        raise AdapterRequestBoundary::Error, "work_expired" unless
          work.state == "leased" && work.lease_expires_at&.>(Time.zone.now)
        raise AdapterRequestBoundary::Error, "stage_conflict" unless work.last_acknowledged_stage.nil?
        dynamic = payload["deployment_state"] == "not_required"
        valid = if dynamic
          payload["verification_state"] == "not_required"
        else
          payload["deployment_state"] == "pending" && payload["verification_state"] == "pending"
        end
        valid &&= !payload.key?("deployed_at") && !payload.key?("publicly_verified_at")
        raise AdapterRequestBoundary::Error, "stage_conflict" unless valid
      when "deployed"
        raise AdapterRequestBoundary::Error, "stage_conflict" unless
          work.state == "awaiting_deployment" && work.last_acknowledged_stage == "synchronized" &&
            payload["deployment_state"] == "deployed" && payload["verification_state"] == "pending" &&
            payload.key?("deployed_at") && !payload.key?("publicly_verified_at")
        deployed_at = PublicationWorkProtocol.parse_time!(payload.fetch("deployed_at"))
        raise AdapterRequestBoundary::Error, "stage_conflict" if deployed_at < synchronized_at
      when "verified"
        raise AdapterRequestBoundary::Error, "stage_conflict" unless
          work.state == "awaiting_verification" && work.last_acknowledged_stage == "deployed" &&
            payload["deployment_state"] == "deployed" && payload["verification_state"] == "verified" &&
            payload.key?("deployed_at") && payload.key?("publicly_verified_at")
        deployed_at = PublicationWorkProtocol.parse_time!(payload.fetch("deployed_at"))
        verified_at = PublicationWorkProtocol.parse_time!(payload.fetch("publicly_verified_at"))
        raise AdapterRequestBoundary::Error, "stage_conflict" if
          deployed_at < synchronized_at || verified_at < deployed_at
      end
    end

    def validate_content_disposition!(work, disposition)
      revision = work.source_revision_record
      return unless revision

      maximum = work.native_limit_policy.fetch("maximum_bytes")
      if revision.byte_length <= maximum
        raise AdapterRequestBoundary::Error, "validation_failed" unless disposition == "complete"
      else
        raise AdapterRequestBoundary::Error, "validation_failed" unless
          work.native_limit_policy.fetch("overflow_behavior") == "excerpt_with_read_more" &&
            disposition == "excerpt"
      end
    end

    def apply_acknowledgement!(work, payload)
      stage = payload.fetch("stage")
      binding = work.content_binding
      destination = payload.fetch("destination_binding")
      synchronized_at = PublicationWorkProtocol.parse_time!(payload.fetch("synchronized_at"))
      common_binding = {
        applied_source_revision: work.source_revision,
        publication_revision: destination.fetch("publication_revision"),
        content_disposition: destination.fetch("content_disposition"),
        synchronized_at: synchronized_at,
      }
      response = { work_id: work.work_id, accepted_stage: stage }
      case stage
      when "synchronized"
        if payload.fetch("deployment_state") == "not_required"
          binding.update!(
            **common_binding,
            deployment_state: "not_required",
            verification_state: "not_required",
          )
          work.update!(
            state: "acknowledged",
            last_acknowledged_stage: stage,
            synchronized_at: synchronized_at,
            acknowledged_at: Time.zone.now,
          )
          response.merge!(resulting_state: "acknowledged", terminal: true)
        else
          next_token = PublicationWorkProtocol.token
          binding.update!(
            **common_binding,
            deployment_state: "pending",
            verification_state: "pending",
          )
          work.update!(
            state: "awaiting_deployment",
            last_acknowledged_stage: stage,
            synchronized_at: synchronized_at,
            stage_token_digest: PublicationWorkProtocol.token_digest(next_token),
          )
          response.merge!(
            resulting_state: "awaiting_deployment",
            terminal: false,
            next_stage_token: next_token,
          )
        end
      when "deployed"
        next_token = PublicationWorkProtocol.token
        deployed_at = PublicationWorkProtocol.parse_time!(payload.fetch("deployed_at"))
        binding.update!(deployment_state: "deployed", deployed_at: deployed_at)
        work.update!(
          state: "awaiting_verification",
          last_acknowledged_stage: stage,
          deployed_at: deployed_at,
          stage_token_digest: PublicationWorkProtocol.token_digest(next_token),
        )
        response.merge!(
          resulting_state: "awaiting_verification",
          terminal: false,
          next_stage_token: next_token,
        )
      when "verified"
        deployed_at = PublicationWorkProtocol.parse_time!(payload.fetch("deployed_at"))
        verified_at = PublicationWorkProtocol.parse_time!(payload.fetch("publicly_verified_at"))
        binding.update!(
          deployment_state: "deployed",
          deployed_at: deployed_at,
          verification_state: "verified",
          publicly_verified_at: verified_at,
        )
        work.update!(
          state: "acknowledged",
          last_acknowledged_stage: stage,
          deployed_at: deployed_at,
          publicly_verified_at: verified_at,
          acknowledged_at: Time.zone.now,
        )
        response.merge!(resulting_state: "acknowledged", terminal: true)
      end
      response
    end

    def validate_failure!(work, payload)
      raise AdapterRequestBoundary::Error, "work_superseded" if work.state == "superseded"
      raise AdapterRequestBoundary::Error, "stage_conflict" if
        %w[leased awaiting_deployment awaiting_verification].exclude?(work.state)
      raise AdapterRequestBoundary::Error, "lease_conflict" unless
        PublicationWorkProtocol.secure_token_match?(work.lease_token_digest, payload["lease_token"])
      raise AdapterRequestBoundary::Error, "validation_failed" if
        PublicationWorkProtocol::FAILURE_CODES.exclude?(payload["error_code"])
      PublicationWorkProtocol.safe_error_detail!(
        payload["error_detail"],
        lease_token: payload["lease_token"],
      )
      PublicationWorkProtocol.parse_time!(payload["failed_at"])
    end

    def mark_binding_failure!(work)
      case work.last_acknowledged_stage
      when "synchronized"
        work.content_binding.update!(deployment_state: "failed")
      when "deployed"
        work.content_binding.update!(verification_state: "failed")
      end
    end

    def find_work(work_id)
      raise AdapterRequestBoundary::Error, "not_found" unless
        PublicationWorkProtocol::WORK_ID_PATTERN.match?(work_id.to_s)

      @connection.publication_works.find_by!(work_id: work_id)
    end
  end
end
