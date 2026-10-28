# frozen_string_literal: true

require "digest"
require "securerandom"

module DiscussionBridge
  class CmsAttentionRecovery
    Result = Data.define(:status, :body)
    PAGE_SIZE = 25
    CANDIDATE = "discussionbridge-v4-core-20261025-r6"

    def initialize(connection, clock: -> { Time.current }, authenticated_secret_digest: nil, native_authorizer: nil)
      @connection = connection
      @clock = clock
      @authenticated_secret_digest = authenticated_secret_digest
      @native_authorizer = native_authorizer
    end

    def capability
      connection_transaction do |configuration|
        response("AttentionRecoveryCapability", {
          "protocol_revision" => "attention-recovery-1", "candidate_id" => CANDIDATE,
          "inspection_profiles" => [CmsAttentionEvidence::PROFILES.fetch(configuration.fetch("profile"))],
        })
      end
    end

    def inspections(after: 0)
      connection_transaction do |_configuration|
        feed(DiscussionBridgeCmsAttentionInspection, "AttentionInspectionPage", after) do |row|
          CmsReceiptCipher.decrypt(row.payload_tree)
        end
      end
    end

    def recoveries(after: 0)
      connection_transaction do |_configuration|
        feed(DiscussionBridgeCmsAttentionRecovery, "AttentionRecoveryPage", after) do |row|
          CmsReceiptCipher.decrypt(row.payload_tree)
        end
      end
    end

    def report(inspection_id, input)
      CmsProtocol.validate!("UUID", inspection_id)
      CmsProtocol.validate!("AttentionInspectionReport", input)
      connection_transaction do |configuration|
        mutation("attention_report", inspection_id, input) do
          inspection = owned_inspection!(inspection_id)
          inspection.lock!
          unless inspection.context_sha256 == input.fetch("context_sha256")
            CmsProtocol.reject!("revision_conflict")
          end
          observation = input.fetch("observation")
          if inspection.observation_tree
            unless same?(CmsReceiptCipher.decrypt(inspection.observation_tree), observation)
              CmsProtocol.reject!("mutation_conflict")
            end
          end
          outcome = classify(inspection, observation, configuration)
          inspection.update!(
            observation_tree: CmsReceiptCipher.encrypt(observation),
            observed_at: Time.iso8601(observation.fetch("observed_at")),
            status: outcome.fetch("status"), issue: outcome.fetch("issue"),
          )
          response("AttentionInspectionResult", inspection_result(inspection))
        end
      end
    end

    def claim(recovery_id, input)
      CmsProtocol.validate!("UUID", recovery_id)
      CmsProtocol.validate!("AttentionRecoveryClaim", input)
      connection_transaction do |_configuration|
        recovery = DiscussionBridgeCmsAttentionRecovery.find_by(
          content_connection_id: @connection.id, recovery_id: recovery_id,
        )
        CmsProtocol.reject!("resource_not_found") unless recovery
        work = recovery.successor_work
        CmsProtocol.reject!("identity_conflict") unless input.fetch("work_id") == work.work_id
        coordinator.claim(
          { "mutation_id" => input.fetch("mutation_id"), "mapping_id" => recovery.cms_mapping.mapping_id },
          expected_work_id: work.work_id,
          receipt_route: "attention_recovery_claim", receipt_path: work.work_id,
        )
      end
    end

    def check(actor:, input:)
      CmsProtocol.validate!("AttentionAdminCheck", input)
      native_action("attention_admin_check", actor, input) do |configuration|
        input.fetch("selected").map do |selection|
          per_item(selection.fetch("work_id")) do
            work = owned_work!(selection.fetch("work_id"))
            mapping = lock_work!(work, actor)
            unless mapping.mapping_revision == selection.fetch("mapping_revision")
              CmsProtocol.reject!("revision_conflict")
            end
            prepared = mapping.prepared_transaction
            if prepared && %w[work_id action source_revision policy_revision lease_generation].any? { |key| prepared[key] != work.public_send(key) }
              # A prior intent's preparation is not the selected failed Work.
              # Preserve it for a separately authorized recovery decision.
              next admin_item(work.work_id, status: "not_ready", issue: "context_changed")
            end
            payload, context = current_context!(work, configuration)
            # Each explicit Check may request fresh observations of the same
            # context; only the exact native action UUID is replayed. Earlier
            # evidence remains retained, and cannot authorize a later Check.
            inspection = DiscussionBridgeCmsAttentionInspection.create!(
              inspection_id: SecureRandom.uuid, content_connection_id: @connection.id,
              cms_mapping_id: mapping.id, cms_work_id: work.id, actor_user_id: actor.id,
              context_sha256: context, payload_tree: CmsReceiptCipher.encrypt({}),
              status: "waiting", issue: "none", created_at: now,
            )
            sequence!(inspection.id)
            payload.merge!("sequence" => inspection.id, "inspection_id" => inspection.inspection_id,
              "context_sha256" => context, "created_at" => CmsProtocol.instant(now))
            CmsProtocol.validate!("AttentionInspection", payload)
            inspection.update!(payload_tree: CmsReceiptCipher.encrypt(payload))
            admin_item(work.work_id, inspection: inspection, status: "waiting")
          end
        end
      end
    end

    def retry_selected(actor:, input:)
      CmsProtocol.validate!("AttentionAdminRetry", input)
      native_action("attention_admin_retry", actor, input) do |configuration|
        # Reject an unresolvable/foreign selection before any item changes. Every
        # real retained inspection then has its real work ID in per-item errors.
        selected_rows = input.fetch("selected").to_h do |selection|
          id = selection.fetch("inspection_id")
          [id, owned_inspection!(id)]
        end
        input.fetch("selected").map do |selection|
          inspection = selected_rows.fetch(selection.fetch("inspection_id"))
          per_item(inspection.cms_work.work_id, inspection.inspection_id) do
            work = inspection.cms_work
            mapping = lock_work!(work, actor)
            inspection.lock!
            unless inspection.context_sha256 == selection.fetch("context_sha256")
              CmsProtocol.reject!("revision_conflict")
            end
            existing = DiscussionBridgeCmsAttentionRecovery.find_by(predecessor_work_id: work.id)
            if existing
              expected = selection.fetch("settle_restored_baseline") ? "settle_restored_baseline" : "retry"
              CmsProtocol.reject!("mutation_conflict") unless existing.mode == expected
              next admin_item(work.work_id, inspection: inspection, recovery: existing, status: "queued")
            end
            observation = inspection.observation_tree && CmsReceiptCipher.decrypt(inspection.observation_tree)
            if observation.nil?
              next admin_item(work.work_id, inspection: inspection, status: "waiting")
            end
            outcome = classify(inspection, observation, configuration)
            unless outcome.fetch("status") == "ready"
              next admin_item(work.work_id, inspection: inspection, **outcome.transform_keys(&:to_sym))
            end
            CmsCatalogAvailabilityLifecycle.assert_publication_available!(
              @connection, configuration: configuration, action: work.action,
            )
            recovery = admit!(work, mapping, inspection, observation, actor,
              settle: selection.fetch("settle_restored_baseline"), configuration: configuration)
            admin_item(work.work_id, inspection: inspection, recovery: recovery, status: "queued")
          end
        end
      end
    end

    # Native administration only. Describes current evidence, never admits work.
    def projection(mapping, work)
      return nil unless work
      inspection = DiscussionBridgeCmsAttentionInspection.where(cms_work_id: work.id).order(id: :desc).first
      configuration = CmsConfiguration.current!(@connection, require_enabled: true)
      restored = work.state == "attention" && %w[catalog_entry_unavailable metadata_unavailable].include?(work.last_failure_code) &&
        work.policy_revision == configuration.fetch("policy").fetch("policy_revision") &&
        CmsCatalogAvailabilityLifecycle.publication_eligible?(@connection, configuration: configuration, action: work.action)
      outcome = inspection && inspection_result(inspection)
      if inspection
        observation = inspection.observation_tree && CmsReceiptCipher.decrypt(inspection.observation_tree)
        classified = classify(inspection, observation, configuration)
        outcome.merge!(classified)
      end
      { "can_check" => work.state == "attention" && !work.same_intent_hold?,
        "metadata_restored" => !!restored, "inspection" => outcome,
        "settlement_required" => mapping.prepared_transaction.present?,
        "mapping_revision" => mapping.mapping_revision }
    rescue CmsProtocol::Error, SourceEdition::Unavailable, SourceEdition::InvalidForumName
      { "can_check" => false, "metadata_restored" => false, "inspection" => nil,
        "settlement_required" => mapping.prepared_transaction.present?,
        "mapping_revision" => mapping.mapping_revision }
    end

    private

    def now = @clock.call.utc
    def same?(left, right) = CmsProtocol.semantic_identity(left) == CmsProtocol.semantic_identity(right)

    def coordinator
      @coordinator ||= CmsWorkCoordinator.new(@connection, clock: @clock,
        authenticated_secret_digest: @authenticated_secret_digest)
    end

    def connection_transaction(require_enabled: false)
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        if @authenticated_secret_digest &&
             !ActiveSupport::SecurityUtils.secure_compare(@authenticated_secret_digest, @connection.secret_digest)
          CmsProtocol.reject!("authentication_failed")
        end
        configuration = CmsConfiguration.current!(@connection, require_enabled: require_enabled)
        yield configuration
      end
    end

    def native_action(route, actor, input)
      authorize_native_actor!(actor)
      connection_transaction(require_enabled: true) do |configuration|
        authorize_native_actor!(actor)
        mutation(route, @connection.id.to_s, input, actor: actor) do
          items = yield(configuration)
          authorize_native_actor!(actor) # Recheck after the selected batch.
          response("AttentionAdminResult", { "mutation_id" => input.fetch("mutation_id"), "items" => items })
        end
      end
    end

    def authorize_native_actor!(actor)
      if @native_authorizer
        @native_authorizer.call(actor, @connection)
      else
        CmsAuthorityLifecycle.administrator!(actor)
      end
    end

    def mutation(route, path, input, actor: nil)
      keys = { content_connection_id: @connection.id, route: route, path_resource: path,
               mutation_id: input.fetch("mutation_id") }
      if receipt = DiscussionBridgeCmsMutationReceipt.find_by(keys)
        unless same?(CmsReceiptCipher.decrypt(receipt.request_tree), input) &&
             (!actor || receipt.native_actor_user_id == actor.id)
          CmsProtocol.reject!("mutation_conflict")
        end
        return Result.new(status: receipt.response_status,
          body: receipt.response_body && CmsReceiptCipher.decrypt(receipt.response_body))
      end
      result = yield
      DiscussionBridgeCmsMutationReceipt.create!(**keys, native_actor_user_id: actor&.id,
        request_tree: CmsReceiptCipher.encrypt(input), response_status: result.status,
        response_body: result.body && CmsReceiptCipher.encrypt(result.body))
      result
    end

    def per_item(work_id, inspection_id = nil)
      DiscussionBridgeContentConnection.transaction(requires_new: true) { yield }
    rescue CmsProtocol::Error, SourceEdition::Unavailable, SourceEdition::InvalidForumName, Discourse::InvalidAccess => error
      code = error.is_a?(CmsProtocol::Error) ? error.code : "source_ineligible"
      admin_item(work_id, inspection_id: inspection_id,
        status: code == "revision_conflict" ? "stale" : "conflict", issue: issue_for(code))
    end

    def issue_for(code)
      return "metadata_unavailable" if %w[catalog_entry_unavailable metadata_unavailable].include?(code)
      return "native_conflict" if %w[native_ownership_conflict identity_conflict].include?(code)
      "context_changed"
    end

    def owned_work!(uuid)
      CmsProtocol.validate!("UUID", uuid)
      coordinator.send(:owned_work!, uuid)
    end

    def owned_inspection!(uuid)
      row = DiscussionBridgeCmsAttentionInspection.find_by(content_connection_id: @connection.id, inspection_id: uuid)
      CmsProtocol.reject!("resource_not_found") unless row
      row
    end

    def lock_work!(work, actor = nil)
      mapping = work.cms_mapping
      mapping.lock!
      work.lock!
      if actor
        authorize_native_actor!(actor)
        topic = mapping.content_binding.bridge_record.topic
        actor.guardian.ensure_can_see!(topic)
        @native_authorizer&.authorize_topic!(actor, topic)
      end
      coordinator.send(:scoped_mapping!, mapping, enabled: true)
      mapping
    end

    def current_context!(work, configuration)
      mapping = work.cms_mapping
      unless work.state == "attention" && !work.same_intent_hold? &&
           mapping.work_items.order(created_at: :desc, id: :desc).first&.id == work.id
        CmsProtocol.reject!("invalid_transition")
      end
      CmsConfiguration.current!(@connection, require_enabled: true)
      coordinator.send(:scoped_mapping!, mapping, enabled: true)
      coordinator.send(:current_work!, work, configuration)
      prepared = mapping.prepared_transaction&.deep_dup
      if prepared
        prepared["deployment_id"] ||= nil
        prepared["deployed_at"] ||= nil
      end
      payload = {
        "work" => coordinator.send(:work_payload, work),
        "mapping" => CmsMappingProjection.call(mapping, configuration: configuration),
        "source" => work.source_snapshot,
        "native_result" => mapping.native_result,
        "verified_native_result" => mapping.verified_result&.fetch("native_result", nil),
        "verification" => mapping.verified_result&.fetch("verification", nil),
        "prepared_transaction" => prepared,
      }
      stream = DiscussionBridgeCmsSourceStream.find_by(content_connection_id: @connection.id,
        publication_lane: configuration.fetch("publication_lane"))
      catalog = CmsCatalogAvailabilityLifecycle.selection_issue(@connection, configuration: configuration)
      context = {
        "payload" => payload, "configuration" => configuration,
        "connection_scope" => CmsSourceStore.new(@connection).scope_fingerprint(configuration,
          source_scope_revision: stream&.source_scope_revision || 0),
        "secret_binding" => @connection.secret_digest, "fence" => mapping.fence_generation,
        "failure_detail" => work.failure_detail, "catalog" => catalog.availability.to_h,
        "open_moves" => DiscussionBridgeCmsUrlMove.where(cms_mapping_id: mapping.id,
          state: %w[prepared attention]).order(:id).pluck(:move_id, :state),
      }
      [payload, Digest::SHA256.hexdigest(CmsProtocol.semantic_identity(context))]
    end

    def classify(inspection, observation, configuration)
      work = inspection.cms_work
      latest = DiscussionBridgeCmsAttentionInspection.where(cms_work_id: work.id).order(id: :desc).first
      return { "status" => "stale", "issue" => "context_changed" } unless latest&.id == inspection.id
      payload, context = current_context!(work, configuration)
      return { "status" => "stale", "issue" => "context_changed" } unless context == inspection.context_sha256
      return { "status" => "waiting", "issue" => "none" } unless observation
      if DiscussionBridgeCmsUrlMove.where(cms_mapping_id: work.cms_mapping_id, state: %w[prepared attention]).exists?
        return { "status" => "not_ready", "issue" => "url_move_open" }
      end
      unless CmsCatalogAvailabilityLifecycle.publication_eligible?(@connection,
          configuration: configuration, action: work.action)
        return { "status" => "not_ready", "issue" => "metadata_unavailable" }
      end
      CmsAttentionEvidence.evaluate(payload, observation, profile: configuration.fetch("profile"),
        publication_kind: configuration.fetch("policy").fetch("publication_kind"))
    rescue CmsProtocol::Error, SourceEdition::Unavailable, SourceEdition::InvalidForumName
      { "status" => "stale", "issue" => "context_changed" }
    end

    def admit!(work, mapping, inspection, observation, actor, settle:, configuration:)
      prepared = mapping.prepared_transaction
      required = prepared.present?
      unless settle == required && (!required || observation.fetch("native_state") == "restored_baseline")
        CmsProtocol.reject!("invalid_transition")
      end
      snapshot = {
        "work" => work.attributes.except("lease_verifier"), "mapping" => mapping.attributes,
        "inspection" => CmsReceiptCipher.decrypt(inspection.payload_tree), "observation" => observation,
      }
      if required
        # The classifier proved actual restored native AND public baseline. Only
        # this explicit named action may archive and clear this exact preparation.
        unless prepared.fetch("transaction_id") == observation.fetch("prepared_transaction_id") &&
             prepared.fetch("work_id") == work.work_id && prepared.fetch("lease_generation") == work.lease_generation
          CmsProtocol.reject!("revision_conflict")
        end
        baseline = mapping.verified_result.fetch("native_result")
        mapping.update!(native_result: baseline, prepared_transaction: nil,
          synchronized_source_revision: mapping.publicly_verified_source_revision,
          destination_native_revision: baseline.fetch("native_revision"))
      end
      successor = mapping.work_items.create!(
        work_id: SecureRandom.uuid, attempt_cycle: SecureRandom.uuid, retry_of_work_id: work.id,
        action: work.action, state: "pending", attempt: 0, source_revision: work.source_revision,
        lease_generation: mapping.fence_generation,
        policy_revision: work.policy_revision, source_snapshot: work.source_snapshot,
      )
      work.update!(state: "superseded", lease_verifier: nil, lease_expires_at: nil, retry_at: nil)
      mapping.update!(mapping_state: "pending")
      mode = required ? "settle_restored_baseline" : "retry"
      recovery = DiscussionBridgeCmsAttentionRecovery.create!(
        recovery_id: SecureRandom.uuid, content_connection_id: @connection.id,
        cms_mapping_id: mapping.id, inspection_record_id: inspection.id,
        predecessor_work_id: work.id, successor_work_id: successor.id, actor_user_id: actor.id,
        context_sha256: inspection.context_sha256, mode: mode,
        payload_tree: CmsReceiptCipher.encrypt({}), attention_snapshot: CmsReceiptCipher.encrypt(snapshot), created_at: now,
      )
      sequence!(recovery.id)
      body = { "sequence" => recovery.id, "recovery_id" => recovery.recovery_id,
        "inspection_id" => inspection.inspection_id, "context_sha256" => inspection.context_sha256,
        "predecessor_work_id" => work.work_id, "predecessor_attempt_cycle" => work.attempt_cycle,
        "work" => coordinator.send(:work_payload, successor),
        "mapping" => CmsMappingProjection.call(mapping, configuration: configuration),
        "source" => successor.source_snapshot, "mode" => mode,
        "native_baseline" => observation["native_result"], "verification" => observation["verification"],
        "created_at" => CmsProtocol.instant(now) }
      CmsProtocol.validate!("AttentionRecovery", body)
      # The record becomes immutable after its one transaction is committed.
      DiscussionBridgeCmsAttentionRecovery.where(id: recovery.id).update_all(payload_tree: CmsReceiptCipher.encrypt(body))
      recovery
    end

    def feed(model, type, after)
      CmsProtocol.validate!("UInt", after)
      configuration = CmsConfiguration.current!(@connection)
      origin = CmsProtocol.url_key(configuration.fetch("destination_origin")).delete_suffix("/")
      rows = model.joins(cms_mapping: { content_binding: :bridge_record })
        .where(content_connection_id: @connection.id)
        .where(discussion_bridge_content_bindings: { state: "active", role: "presentation", content_connection_id: @connection.id })
        .where(discussion_bridge_bridge_records: { direction: "from_discourse", lane: configuration.fetch("publication_lane") })
        .where("discussion_bridge_content_bindings.canonical_url LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(origin)}/%")
        .where("#{model.table_name}.id > ?", after).order("#{model.table_name}.id").limit(PAGE_SIZE + 1).to_a
      items = []
      has_more = rows.length > PAGE_SIZE
      rows.first(PAGE_SIZE).each do |row|
        item = yield row
        # Current connection scope is rechecked for each historical feed item.
        # A narrower/changed connection must not receive a former scope's target.
        mapping_id = item.fetch("mapping").fetch("mapping_id")
        mapping = DiscussionBridgeCmsMapping.find_by(content_connection_id: @connection.id, mapping_id: mapping_id)
        CmsProtocol.reject!("scope_denied") unless mapping
        coordinator.send(:scoped_mapping!, mapping)
        candidate = { "items" => items + [item], "next_after" => row.id, "has_more" => has_more }
        if JSON.generate(candidate).bytesize > 262_144
          CmsProtocol.reject!("metadata_unavailable") if items.empty?
          has_more = true
          break
        end
        items << item
      end
      page = { "items" => items, "next_after" => items.last&.fetch("sequence") || after,
               "has_more" => has_more }
      CmsProtocol.validate_attention_feed_page!(type, page, after)
      response(type, page)
    end

    def sequence!(value)
      CmsProtocol.reject!("storage_exhausted") unless value.is_a?(Integer) && value.between?(1, CmsProtocol::MAX_COUNTER)
    end

    def inspection_result(row)
      { "inspection_id" => row.inspection_id, "context_sha256" => row.context_sha256,
        "status" => row.status, "issue" => row.issue, "observed_at" => CmsProtocol.instant(row.observed_at) }
    end

    def admin_item(work_id, inspection: nil, inspection_id: nil, recovery: nil, status:, issue: "none")
      { "work_id" => work_id, "inspection_id" => inspection&.inspection_id || inspection_id,
        "recovery_id" => recovery&.recovery_id, "successor_work_id" => recovery&.successor_work&.work_id,
        "status" => status, "issue" => issue }
    end

    def response(type, body)
      CmsProtocol.validate!(type, body)
      CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > 262_144
      Result.new(status: 200, body: body)
    end
  end
end
