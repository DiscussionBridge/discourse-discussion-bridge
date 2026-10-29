# frozen_string_literal: true

require "digest"
require "securerandom"

module DiscussionBridge
  class CmsWorkCoordinator
    Result = Data.define(:status, :body)
    TRANSIENT_CODES = %w[rate_limited transport_timeout native_service_unavailable].freeze
    LEASE_SECONDS = 300
    MAINTENANCE_BATCH_SIZE = 100

    # Receiver-only timer work; it neither discovers source nor issues leases.
    def self.maintenance(clock: -> { Time.current })
      return 0 if Discourse.readonly_mode? || !CmsSourceLifecycle.globally_enabled?
      processed = 0
      DiscussionBridgeContentConnection
        .where(enabled: true)
        .where.not(cms_configuration: nil)
        .find_each(batch_size: MAINTENANCE_BATCH_SIZE) do |connection|
          begin
            processed += new(connection, clock: clock).maintain_due!
          rescue CmsProtocol::Error => error
            if %w[
                     connection_disabled
                     scope_denied
                     invalid_field
                     unknown_field
                     presentation_unsupported
                   ].exclude?(error.code)
              raise
            end
            # Current scope prevents work; the authority/lifecycle path retains
            # its own cancellation/attention evidence. Never repair selections.
          end
        end
      processed
    end

    def initialize(connection, clock: -> { Time.current }, authenticated_secret_digest: nil)
      @connection = connection
      @clock = clock
      @authenticated_secret_digest = authenticated_secret_digest
    end

    # Called only by the receiver's policy/source-intent path. A filtered claim
    # never enters here and can never synthesize publication work.
    def enqueue!(mapping, source_snapshot:, action: "publish_revision")
      DiscussionBridgeCmsMapping.transaction do
        @connection.lock!
        config = scoped_mapping!(mapping, enabled: true)
        mapping.lock!
        policy = config.fetch("policy")
        topic = mapping.content_binding.bridge_record.topic
        if action == "publish_revision"
          CmsProtocol.reject!("source_ineligible") unless CmsConfiguration.eligible?(topic, policy)
          CmsProtocol.validate!("Source", source_snapshot)
          unless source_snapshot.fetch("source_id") == mapping.source_id &&
                   source_snapshot.fetch("topic_id") == topic.id.to_s
            CmsProtocol.reject!("identity_conflict")
          end
          revision = source_snapshot.fetch("source_revision")
        elsif action == "withdraw"
          CmsProtocol.reject!("native_ownership_conflict") unless mapping.destination_native_id
          CmsProtocol.reject!("invalid_field") unless source_snapshot.nil?
          revision = nil
        else
          CmsProtocol.reject!("invalid_field")
        end
        CmsCatalogAvailabilityLifecycle.assert_publication_available!(
          @connection,
          configuration: config,
          action: action,
        )
        existing = mapping.work_items.order(created_at: :desc, id: :desc).first
        if existing && existing.action == action && existing.source_revision == revision &&
             existing.policy_revision == policy.fetch("policy_revision") &&
             (!%w[cancelled superseded].include?(existing.state) || existing.same_intent_hold?)
          unless existing.source_snapshot == source_snapshot
            CmsProtocol.reject!("revision_conflict")
          end
          return existing
        end
        mapping
          .work_items
          .where(state: DiscussionBridgeCmsWork::UNCOMPLETED_STATES)
          .update_all(
            state: "superseded",
            lease_verifier: nil,
            lease_expires_at: nil,
            updated_at: now,
          )
        blocked_by_preparation = mapping.prepared_transaction.present?
        changes = {
          desired_source_revision: revision,
          mapping_state: blocked_by_preparation ? "attention" : "pending",
        }
        if source_snapshot
          changes[:source_created_at] = source_snapshot.fetch("source_created_at")
          changes[:source_updated_at] = source_snapshot.fetch("source_updated_at")
        end
        mapping.update!(changes)
        work = mapping.work_items.create!(
          work_id: SecureRandom.uuid,
          attempt_cycle: SecureRandom.uuid,
          action: action,
          state: blocked_by_preparation ? "attention" : "pending",
          last_failure_code: blocked_by_preparation ? "native_restore_required" : nil,
          source_revision: revision,
          policy_revision: policy.fetch("policy_revision"),
          source_snapshot: source_snapshot,
        )
        CmsAttentionNotifications.record!(work) if blocked_by_preparation
        work
      end
    end

    def claim(input, expected_work_id: nil, receipt_route: "claim", receipt_path: "")
      CmsProtocol.validate!("Claim", input)
      CmsProtocol.validate!("UUID", expected_work_id) if expected_work_id
      mutation(receipt_route, receipt_path, input) do
        CmsConfiguration.current!(@connection, require_enabled: true)
        scope =
          DiscussionBridgeCmsWork.joins(:cms_mapping).where(
            discussion_bridge_cms_mappings: {
              content_connection_id: @connection.id,
            },
          )
        scope =
          scope.where(
            discussion_bridge_cms_mappings: {
              mapping_id: input["mapping_id"],
            },
          ) if input.key?("mapping_id")
        expire_due!(scope)
        scope
          .where(state: "retry_wait")
          .where("retry_at <= ?", now)
          .find_each { |candidate| resume_due_retry!(candidate) }
        # A recovery successor is activated only through its exact positive
        # recovery handoff. A legacy/general claim cannot omit that context.
        eligible_scope = expected_work_id ? scope.where(work_id: expected_work_id) : scope.where(retry_of_work_id: nil)
        work =
          eligible_scope
            .where(state: "pending")
            .order(:created_at, :work_id)
            .detect do |candidate|
              mapping = candidate.cms_mapping
              config = scoped_mapping!(mapping, enabled: true)
              if mapping.work_items.where(state: DiscussionBridgeCmsWork::LIVE_STATES).exists?
                next false
              end
              current_work!(candidate, config)
              unless CmsCatalogAvailabilityLifecycle.publication_eligible?(
                       @connection,
                       configuration: config,
                       action: candidate.action,
                     )
                next false
              end
              true
            end
        next Result.new(status: 204, body: nil) unless work
        mapping = work.cms_mapping
        mapping.lock!
        work.lock!
        if mapping.fence_generation >= CmsProtocol::MAX_COUNTER
          CmsProtocol.reject!("storage_exhausted")
        end
        CmsProtocol.reject!("invalid_transition") if work.attempt >= 3
        token = SecureRandom.urlsafe_base64(32, false)
        generation = mapping.fence_generation + 1
        mapping.update!(fence_generation: generation)
        work.update!(
          state: "leased",
          attempt: work.attempt + 1,
          lease_generation: generation,
          lease_verifier: Digest::SHA256.hexdigest(token),
          lease_expires_at: now + LEASE_SECONDS,
          retry_at: nil,
        )
        Result.new(status: 200, body: lease_payload(work, token))
      end
    end

    def query(work_id)
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        authenticate_current_secret!
        work = owned_work!(work_id)
        scoped_mapping!(work.cms_mapping)
        Result.new(status: 200, body: status_payload(work))
      end
    end

    def maintain_due!(limit: MAINTENANCE_BATCH_SIZE)
      unless limit.is_a?(Integer) && limit.between?(1, MAINTENANCE_BATCH_SIZE)
        raise ArgumentError, "Invalid receiver maintenance batch"
      end
      return 0 if Discourse.readonly_mode? || !CmsSourceLifecycle.globally_enabled?
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        config = CmsConfiguration.current!(@connection)
        next 0 unless config.fetch("policy").fetch("enabled")
        scope =
          DiscussionBridgeCmsWork.joins(:cms_mapping).where(
            discussion_bridge_cms_mappings: {
              content_connection_id: @connection.id,
            },
          )
        due =
          scope
            .where(
              "(discussion_bridge_cms_work.state IN (?) AND lease_expires_at <= ?) " \
                "OR (discussion_bridge_cms_work.state = ? AND retry_at <= ?)",
              DiscussionBridgeCmsWork::LIVE_STATES,
              now,
              "retry_wait",
              now,
            )
            .order(:created_at, :work_id)
            .limit(limit)
            .to_a
        due.each do |work|
          work.cms_mapping.lock!
          work.lock!
          if DiscussionBridgeCmsWork::LIVE_STATES.include?(work.state) && work.lease_expires_at &&
               work.lease_expires_at <= now
            fail_state!(work, "transport_timeout", failed_at: work.lease_expires_at)
          end
          if work.state == "retry_wait" && work.retry_at && work.retry_at <= now
            resume_due_retry!(work)
          end
        end
        due.length
      end
    end

    def renew(work_id, input)
      mutate_work("renew", "Renew", work_id, input) do |work, _config|
        if DiscussionBridgeCmsWork::LIVE_STATES.exclude?(work.state)
          CmsProtocol.reject!("invalid_transition")
        end
        work.update!(lease_expires_at: now + LEASE_SECONDS)
        Result.new(
          status: 200,
          body: lease_payload(work, input.fetch("authority").fetch("lease_token")),
        )
      end
    end

    def acknowledge(work_id, input)
      mutate_work("acknowledge", "Ack", work_id, input) do |work, config|
        kind = config.fetch("policy").fetch("publication_kind")
        case input.fetch("stage")
        when "synchronized"
          unless kind == "dynamic" && work.state == "leased"
            CmsProtocol.reject!("invalid_transition")
          end
          synchronize!(work, input.fetch("native_result"))
        when "deployed"
          unless kind == "static" && work.state == "synchronized" &&
                   work.cms_mapping.prepared_transaction
            CmsProtocol.reject!("invalid_transition")
          end
          deployment!(work, input.fetch("deployment_id"), input.fetch("deployed_at"))
          work.update!(state: "deployed")
        when "verified"
          unless kind == "dynamic" && work.state == "synchronized"
            CmsProtocol.reject!("invalid_transition")
          end
          verify!(work, input.fetch("verification"), work.cms_mapping.synchronized_at)
        end
        Result.new(status: 200, body: status_payload(work))
      end
    end

    def fail(work_id, input)
      mutate_work("fail", "Failure", work_id, input) do |work, _config|
        if DiscussionBridgeCmsWork::LIVE_STATES.exclude?(work.state)
          CmsProtocol.reject!("invalid_transition")
        end
        delay = input.fetch("retry_after_seconds")
        CmsProtocol.reject!("invalid_field") unless delay.nil? || delay.between?(1, 3600)
        code = input.fetch("code")
        CmsProtocol.reject!("invalid_field") if delay && !TRANSIENT_CODES.include?(code)
        # Never retain arbitrary caller detail: it may contain native exception
        # text or credentials. The bounded receiver code is the safe UI detail.
        work.update!(
          failure_detail: {
            "code" => code,
            "native_change_applied" => input.fetch("native_change_applied"),
          },
        )
        fail_state!(work, code, retry_after: delay)
        Result.new(status: 200, body: status_payload(work))
      end
    end

    def prepare(work_id, input)
      mutate_work("prepare", "StaticPreparation", work_id, input) do |work, config|
        unless config.fetch("policy").fetch("publication_kind") == "static" &&
                 work.state == "leased"
          CmsProtocol.reject!("invalid_transition")
        end
        prepared_at = Time.iso8601(input.fetch("prepared_at"))
        CmsProtocol.reject!("invalid_field") if prepared_at > now + LEASE_SECONDS
        mapping = work.cms_mapping
        existing = mapping.prepared_transaction
        if existing
          matches =
            existing.fetch("transaction_id") == input.fetch("transaction_id") &&
              existing.fetch("work_id") == work.work_id &&
              existing.fetch("action") == work.action &&
              existing["source_revision"] == work.source_revision &&
              existing.fetch("policy_revision") == work.policy_revision &&
              existing.fetch("native_result").except("ownership_receipt_sha256") ==
                input.fetch("native_result").except("ownership_receipt_sha256")
          CmsProtocol.reject!("native_ownership_conflict") unless matches
        end
        synchronize!(work, input.fetch("native_result"), synchronized_at: prepared_at)
        mapping.update!(
          prepared_transaction: {
            "transaction_id" => input.fetch("transaction_id"),
            "work_id" => work.work_id,
            "lease_generation" => work.lease_generation,
            "action" => work.action,
            "source_revision" => work.source_revision,
            "policy_revision" => work.policy_revision,
            "native_result" => input.fetch("native_result"),
            "prepared_at" => input.fetch("prepared_at"),
          },
        )
        Result.new(status: 200, body: status_payload(work))
      end
    end

    def finalize(work_id, input)
      mutate_work("finalize", "StaticFinalize", work_id, input) do |work, config|
        static_transaction!(work, config, input.fetch("transaction_id"))
        deployment!(work, input.fetch("deployment_id"), input.fetch("deployed_at"))
        verify!(work, input.fetch("verification"), Time.iso8601(input.fetch("deployed_at")))
        work.cms_mapping.update!(prepared_transaction: nil)
        Result.new(status: 200, body: status_payload(work))
      end
    end

    def abort(work_id, input)
      mutate_work("abort", "StaticAbort", work_id, input) do |work, config|
        static_transaction!(work, config, input.fetch("transaction_id"))
        mapping = work.cms_mapping
        code =
          (
            if input.fetch("native_restored")
              "public_verification_failed"
            else
              "native_restore_required"
            end
          )
        if input.fetch("native_restored")
          previous = mapping.verified_result
          mapping.update!(
            native_result: previous && previous["native_result"],
            synchronized_source_revision: mapping.publicly_verified_source_revision,
            destination_native_revision:
              previous && previous.dig("native_result", "native_revision"),
            prepared_transaction: nil,
          )
        end
        fail_state!(work, code)
        Result.new(status: 200, body: status_payload(work))
      end
    end

    # Receiver-only settlement of current LIVE publication authority. Waiting
    # work and existing attention retain their original cycle/count/history.
    def fail_receiver_publication!(work, code:)
      if CmsSourceLifecycle::ATTENTION_CODES.exclude?(code)
        raise ArgumentError, "Invalid receiver publication failure"
      end
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        authenticate_current_secret!
        current = owned_work!(work.work_id)
        current.cms_mapping.lock!
        current.lock!
        config = scoped_mapping!(current.cms_mapping, enabled: true)
        unless current.id == work.id && current.action == "publish_revision" &&
                 current.policy_revision == config.fetch("policy").fetch("policy_revision") &&
                 DiscussionBridgeCmsWork::LIVE_STATES.include?(current.state)
          CmsProtocol.reject!("invalid_transition")
        end
        fail_state!(current, code)
        current
      end
    end

    def fail_catalog_metadata!(work, code:)
      if CmsCatalogAvailabilityLifecycle::PERMANENT_CODES.exclude?(code)
        raise ArgumentError, "Invalid permanent catalog failure"
      end
      fail_receiver_publication!(work, code: code)
    end

    private

    def now
      # Compare and persist receiver times at the wire's millisecond precision.
      # A hidden microsecond remainder must not reject a same-instant proof.
      Time.at((@clock.call.to_r * 1000).floor / 1000r).utc
    end

    def mutation(route, path, input)
      DiscussionBridgeCmsMutationReceipt.transaction do
        @connection.lock!
        authenticate_current_secret!
        CmsConfiguration.current!(@connection)
        scoped_mapping!(owned_work!(path).cms_mapping) unless path.empty?
        keys = {
          content_connection_id: @connection.id,
          route: route,
          path_resource: path,
          mutation_id: input.fetch("mutation_id"),
        }
        if receipt = DiscussionBridgeCmsMutationReceipt.find_by(keys)
          unless CmsReceiptCipher.decrypt(receipt.request_tree) == input
            CmsProtocol.reject!("mutation_conflict")
          end
          body = receipt.response_body && CmsReceiptCipher.decrypt(receipt.response_body)
          if %w[claim attention_recovery_claim].include?(route) && receipt.response_status == 200
            CmsProtocol.validate!("Lease", body)
            scoped_mapping!(owned_work!(body.fetch("work").fetch("work_id")).cms_mapping)
          end
          next Result.new(status: receipt.response_status, body: body)
        end
        result = yield
        DiscussionBridgeCmsMutationReceipt.create!(
          **keys,
          request_tree: CmsReceiptCipher.encrypt(input),
          response_status: result.status,
          response_body: result.body && CmsReceiptCipher.encrypt(result.body),
        )
        result
      end
    end

    def mutate_work(route, type, work_id, input)
      CmsProtocol.validate!("UUID", work_id)
      CmsProtocol.validate!(type, input)
      unless input.fetch("authority").fetch("work_id") == work_id
        CmsProtocol.reject!("identity_conflict")
      end
      mutation(route, work_id, input) do
        work = owned_work!(work_id)
        work.cms_mapping.lock!
        work.lock!
        config = scoped_mapping!(work.cms_mapping, enabled: true)
        current_work!(work, config)
        if %w[fail abort].exclude?(route)
          CmsCatalogAvailabilityLifecycle.assert_publication_available!(
            @connection,
            configuration: config,
            action: work.action,
          )
        end
        authority!(work, input.fetch("authority"))
        yield(work, config)
      end
    end

    def owned_work!(work_id)
      work =
        DiscussionBridgeCmsWork.joins(:cms_mapping).find_by(
          work_id: work_id,
          discussion_bridge_cms_mappings: {
            content_connection_id: @connection.id,
          },
        )
      CmsProtocol.reject!("resource_not_found") unless work
      work
    end

    def authenticate_current_secret!
      return unless @authenticated_secret_digest
      unless ActiveSupport::SecurityUtils.secure_compare(
               @authenticated_secret_digest,
               @connection.secret_digest,
             )
        CmsProtocol.reject!("authentication_failed")
      end
    end

    def scoped_mapping!(mapping, enabled: false)
      config = CmsConfiguration.current!(@connection, require_enabled: enabled)
      binding = mapping.content_binding
      unless mapping.content_connection_id == @connection.id
        CmsProtocol.reject!("resource_not_found")
      end
      unless binding.content_connection_id == @connection.id && binding.state == "active" &&
               binding.bridge_record.direction == "from_discourse" &&
               binding.bridge_record.lane.to_s == config.fetch("publication_lane")
        CmsProtocol.reject!("scope_denied")
      end
      CmsConfiguration.destination_url!(@connection, config, binding.canonical_url)
      config
    end

    def current_work!(work, config)
      CmsProtocol.reject!("work_superseded") if %w[cancelled superseded].include?(work.state)
      unless work.policy_revision == config.fetch("policy").fetch("policy_revision")
        CmsProtocol.reject!("policy_changed")
      end
      if work.action == "publish_revision"
        topic = work.cms_mapping.content_binding.bridge_record.topic
        unless CmsConfiguration.eligible?(topic, config.fetch("policy"))
          CmsProtocol.reject!("source_ineligible")
        end
        snapshot = CmsSourceStore.new(@connection, clock: @clock).capture_snapshot(topic)
        unless snapshot.metadata.fetch("source_revision") == work.source_revision
          CmsProtocol.reject!("work_superseded")
        end
      end
    end

    def authority!(work, authority)
      unless work.lease_expires_at && work.lease_expires_at > now
        CmsProtocol.reject!("lease_expired")
      end
      token_digest = Digest::SHA256.hexdigest(authority.fetch("lease_token"))
      valid =
        work.lease_verifier &&
          ActiveSupport::SecurityUtils.secure_compare(work.lease_verifier, token_digest) &&
          work.lease_generation == authority.fetch("lease_generation") &&
          work.cms_mapping.fence_generation == work.lease_generation &&
          work.source_revision == authority.fetch("source_revision") &&
          work.policy_revision == authority.fetch("policy_revision")
      CmsProtocol.reject!("lease_conflict") unless valid
    end

    def expire_due!(scope)
      scope
        .where(state: DiscussionBridgeCmsWork::LIVE_STATES)
        .where("lease_expires_at <= ?", now)
        .find_each do |work|
          work.cms_mapping.lock!
          fail_state!(work, "transport_timeout", failed_at: work.lease_expires_at)
        end
    end

    def resume_due_retry!(work)
      work.cms_mapping.lock!
      work.lock!
      return false unless work.state == "retry_wait" && work.retry_at && work.retry_at <= now
      config = scoped_mapping!(work.cms_mapping, enabled: true)
      current_work!(work, config)
      unless CmsCatalogAvailabilityLifecycle.publication_eligible?(
               @connection,
               configuration: config,
               action: work.action,
             )
        return false
      end
      work.update!(state: "pending", retry_at: nil)
      true
    end

    def fail_state!(work, code, retry_after: nil, failed_at: now)
      transient = TRANSIENT_CODES.include?(code) && work.attempt < 3
      delay = [work.attempt == 1 ? 30 : 120, retry_after || 0].max
      work.update!(
        state: transient ? "retry_wait" : "attention",
        last_failure_code: code,
        retry_at: transient ? failed_at + delay : nil,
        lease_verifier: nil,
        lease_expires_at: nil,
      )
      work.cms_mapping.update!(mapping_state: "attention") unless transient
      CmsAttentionNotifications.record!(work) unless transient
    end

    def synchronize!(work, result, synchronized_at: now)
      if DiscussionBridgeCmsUrlMove.where(cms_mapping_id: work.cms_mapping_id, state: %w[prepared attention]).exists?
        CmsProtocol.reject!("invalid_transition")
      end
      mapping = work.cms_mapping
      binding = mapping.content_binding
      unless result.fetch("kind") == work.action &&
               result.fetch("external_id") == binding.external_id &&
               result.fetch("canonical_url") == binding.canonical_url
        CmsProtocol.reject!("identity_conflict")
      end
      if mapping.destination_native_id && result.fetch("native_id") != mapping.destination_native_id
        CmsProtocol.reject!("native_ownership_conflict")
      end
      if DiscussionBridgeCmsMapping
           .where(
             content_connection_id: @connection.id,
             destination_native_id: result.fetch("native_id"),
           )
           .where.not(id: mapping.id)
           .exists?
        CmsProtocol.reject!("native_ownership_conflict")
      end
      if work.action == "publish_revision"
        representation!(work, result.fetch("representation"))
      elsif !mapping.destination_native_id
        CmsProtocol.reject!("native_ownership_conflict")
      end
      mapping.update!(
        destination_native_id: result.fetch("native_id"),
        destination_native_revision: result.fetch("native_revision"),
        native_result: result,
        synchronized_source_revision: work.source_revision,
        synchronized_at: synchronized_at,
      )
      work.update!(state: "synchronized")
    end

    def representation!(work, representation)
      snapshot = work.source_snapshot
      unless representation.fetch("source_content_sha256") == snapshot.fetch("content_sha256")
        CmsProtocol.reject!("content_hash_mismatch")
      end
      if representation.fetch("kind") == "native_excerpt"
        unless representation.fetch("native_limit_bytes") < snapshot.fetch("content_bytes") &&
                 representation.fetch("read_more_url") == snapshot.fetch("topic_url")
          CmsProtocol.reject!("native_limit_exceeded")
        end
      end
    end

    def static_transaction!(work, config, transaction_id)
      transaction = work.cms_mapping.prepared_transaction
      valid =
        config.fetch("policy").fetch("publication_kind") == "static" &&
          %w[synchronized deployed].include?(work.state) && transaction &&
          transaction.fetch("transaction_id") == transaction_id &&
          transaction.fetch("work_id") == work.work_id &&
          transaction.fetch("lease_generation") == work.lease_generation &&
          transaction.fetch("action") == work.action &&
          transaction["source_revision"] == work.source_revision &&
          transaction.fetch("policy_revision") == work.policy_revision
      CmsProtocol.reject!("invalid_transition") unless valid
    end

    def deployment!(work, deployment_id, deployed_at)
      time = Time.iso8601(deployed_at)
      transaction = work.cms_mapping.prepared_transaction
      unless transaction && time >= Time.iso8601(transaction.fetch("prepared_at")) &&
               time <= now + LEASE_SECONDS
        CmsProtocol.reject!("invalid_field")
      end
      if transaction.key?("deployment_id")
        unless transaction.fetch("deployment_id") == deployment_id &&
                 transaction.fetch("deployed_at") == deployed_at
          CmsProtocol.reject!("identity_conflict")
        end
      end
      work.cms_mapping.update!(
        prepared_transaction:
          transaction.merge("deployment_id" => deployment_id, "deployed_at" => deployed_at),
      )
    end

    def verify!(work, verification, minimum_time)
      mapping = work.cms_mapping
      unless verification.fetch("url") == mapping.content_binding.canonical_url &&
               verification.fetch("native_id") == mapping.destination_native_id
        CmsProtocol.reject!("identity_conflict")
      end
      checked_at = Time.iso8601(verification.fetch("checked_at"))
      unless minimum_time && checked_at >= minimum_time && checked_at <= now + LEASE_SECONDS
        CmsProtocol.reject!("invalid_field")
      end
      expected_kind = work.action == "publish_revision" ? "published" : "absent"
      CmsProtocol.reject!("invalid_transition") unless verification.fetch("kind") == expected_kind
      if expected_kind == "published"
        unless verification.fetch("source_revision") == work.source_revision
          CmsProtocol.reject!("revision_conflict")
        end
        representation!(work, verification.fetch("representation"))
        unless verification.fetch("source_content_sha256") ==
                 work.source_snapshot.fetch("content_sha256")
          CmsProtocol.reject!("content_hash_mismatch")
        end
        unless verification.fetch("representation") == mapping.native_result.fetch("representation")
          CmsProtocol.reject!("public_verification_failed")
        end
      end
      mapping.update!(
        mapping_state: expected_kind == "published" ? "active" : "withdrawn",
        publicly_verified_source_revision: work.source_revision,
        publicly_verified_at: checked_at,
        verified_result: {
          "native_result" => mapping.native_result,
          "verification" => verification,
        },
      )
      work.update!(state: "verified", lease_verifier: nil, lease_expires_at: nil)
    end

    def work_payload(work)
      {
        "work_id" => work.work_id,
        "mapping_id" => work.cms_mapping.mapping_id,
        "source_id" => work.cms_mapping.source_id,
        "source_revision" => work.source_revision,
        "policy_revision" => work.policy_revision,
        "action" => work.action,
        "state" => work.state,
        "attempt_cycle" => work.attempt_cycle,
        "attempt" => work.attempt,
        "lease_generation" => work.lease_generation,
        "retry_at" => CmsProtocol.instant(work.retry_at),
        "last_failure_code" => work.last_failure_code,
      }
    end

    def mapping_payload(mapping)
      CmsMappingProjection.call(mapping, configuration: @connection.cms_configuration)
    end

    def status_payload(work)
      payload = {
        "work" => work_payload(work),
        "mapping" => mapping_payload(work.cms_mapping),
        "lease_expires_at" => CmsProtocol.instant(work.lease_expires_at),
      }
      CmsProtocol.validate!("WorkQueryResponse", payload)
      payload
    end

    def lease_payload(work, token)
      payload = {
        "work" => work_payload(work),
        "lease_token" => token,
        "lease_generation" => work.lease_generation,
        "expires_at" => CmsProtocol.instant(work.lease_expires_at),
        "server_time" => CmsProtocol.instant(now),
      }
      CmsProtocol.validate!("Lease", payload)
      payload
    end
  end
end
