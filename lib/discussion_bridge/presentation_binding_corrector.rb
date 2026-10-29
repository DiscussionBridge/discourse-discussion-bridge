# frozen_string_literal: true

require "securerandom"

module DiscussionBridge
  # Protected native intention, distinct from actual CMS/native URL settlement.
  class PresentationBindingCorrector
    Result = Data.define(:record, :outcome)

    def self.call(user:, resource_id:, canonical_url:, clock: -> { Time.current })
      raise Discourse::InvalidAccess unless user&.staff?
      record = DiscussionBridgeBridgeRecord.find_by!(resource_id: resource_id, direction: "from_discourse")
      user.guardian.ensure_can_see!(record.topic)
      DiscussionBridgeContentConnection.transaction do
        binding = record.active_binding("presentation")
        raise ArgumentError, "Current presentation binding is unavailable" unless binding
        connection = binding.content_connection
        connection.lock!
        configuration = CmsConfiguration.current!(connection, require_enabled: true)
        mapping = DiscussionBridgeCmsMapping.lock.find_by!(content_binding_id: binding.id)
        CmsWorkCoordinator.new(connection, clock: clock).send(:scoped_mapping!, mapping, enabled: true)
        binding.lock!
        record.lock!
        canonical = CanonicalSource.call(connection_id: connection.public_id, source_url: canonical_url).source_url
        CmsProtocol.reject!("invalid_field") unless canonical == canonical_url
        CmsConfiguration.destination_url!(connection, configuration, canonical)
        CmsUrlReservation.with_locks([binding.canonical_url, canonical]) do
          CmsUrlReservation.new.reserve_active!(mapping)
          if binding.canonical_url == canonical
            next Result.new(record: record, outcome: "presentation_unchanged")
          end
          CmsAuthorityLifecycle.administrator!(user)
          CmsUrlMoveProof.urls!(binding.canonical_url, canonical)
          reject_collision!(binding, canonical)
          previous = mapping.presentation_move_intent
          if previous && %w[pending cycle_pending attention].include?(previous["state"])
            raise ArgumentError, "A different presentation move is already pending" unless previous["requested_url"] == canonical
            next Result.new(record: record, outcome: "presentation_pending")
          end
          at = clock.call
          intent = {
            "intent_id" => SecureRandom.uuid, "requested_url" => canonical,
            "requested_at" => CmsProtocol.instant(at), "actor_user_id" => user.id,
            "expected_mapping_revision" => mapping.mapping_revision, "state" => "pending",
          }
          prior = mapping.work_items.lock.order(created_at: :desc, id: :desc).first
          source = nil
          begin
            _source_intent, source, _topic = CmsMappingService.new(connection, clock: clock).send(:current_source!, mapping.source_id)
          rescue CmsProtocol::Error => error
            raise if %w[source_ineligible revision_conflict metadata_unavailable].exclude?(error.code)
            intent.merge!("state" => "attention", "attention_code" => error.code)
          end
          if source && eligible_cycle?(mapping, prior, source, configuration)
            work = mapping.work_items.create!(
              work_id: SecureRandom.uuid, attempt_cycle: SecureRandom.uuid,
              action: "publish_revision", state: "pending", attempt: 0,
              source_revision: prior.source_revision, policy_revision: prior.policy_revision,
              source_snapshot: prior.source_snapshot,
            )
            mapping.update!(mapping_state: "pending")
            intent.merge!("state" => "cycle_pending", "prior_work_id" => prior.work_id,
              "work_id" => work.work_id, "attempt_cycle" => work.attempt_cycle)
            audit!(connection, mapping, user, "url_publication_cycle", {
              "intent_id" => intent.fetch("intent_id"), "prior_work_id" => prior.work_id,
              "prior_attempt_cycle" => prior.attempt_cycle, "prior_attempt" => prior.attempt,
              "work_id" => work.work_id, "attempt_cycle" => work.attempt_cycle, "attempt" => 0,
              "source_revision" => work.source_revision, "policy_revision" => work.policy_revision,
            }, at)
          end
          mapping.update!(presentation_move_intent: intent)
          audit!(connection, mapping, user, "presentation_move_intent", intent, at)
          Result.new(record: record, outcome: "presentation_pending")
        end
      end
    rescue SourceEdition::Unavailable
      raise ArgumentError, "Current native source is unavailable for presentation correction"
    end

    def self.reject_collision!(binding, canonical)
      if DiscussionBridgeCmsUrlReservation.lock.exists?(collision_key_sha256: CmsUrlReservation.collision_digest(canonical))
        CmsProtocol.reject!("url_collision")
      end
      CmsUrlReservation.new.send(:reject_binding_collision!, CmsUrlReservation.collision_key(canonical),
        allowed_binding_id: binding.id)
    end
    private_class_method :reject_collision!

    def self.eligible_cycle?(mapping, prior, source, configuration)
      prior && prior.state == "verified" && prior.action == "publish_revision" &&
        prior.source_revision == source.fetch("source_revision") && prior.source_snapshot == source &&
        prior.policy_revision == configuration.fetch("policy").fetch("policy_revision") &&
        mapping.mapping_state == "active" && mapping.destination_native_id.present? &&
        mapping.native_result.present? && mapping.verified_result.present? &&
        mapping.desired_source_revision == prior.source_revision &&
        mapping.synchronized_source_revision == prior.source_revision &&
        mapping.publicly_verified_source_revision == prior.source_revision &&
        !mapping.prepared_transaction && !prior.same_intent_hold? &&
        !DiscussionBridgeCmsUrlMove.where(cms_mapping_id: mapping.id, state: %w[prepared attention]).exists? &&
        CmsConfiguration.eligible?(mapping.content_binding.bridge_record.topic, configuration.fetch("policy")) &&
        CmsCatalogAvailabilityLifecycle.publication_eligible?(mapping.content_connection,
          configuration: configuration, action: "publish_revision")
    end
    private_class_method :eligible_cycle?

    def self.audit!(connection, mapping, user, kind, facts, at)
      bindings = { connection: connection.id, mapping: mapping.id, actor: user.id,
        kind: kind, facts: JSON.generate(facts), at: at }
      DB.exec(<<~SQL, bindings)
        INSERT INTO discussion_bridge_cms_native_publication_events
          (content_connection_id, cms_mapping_id, actor_user_id, event_kind, facts, created_at)
        VALUES (:connection, :mapping, :actor, :kind, :facts::jsonb, :at)
      SQL
    end
    private_class_method :audit!
  end
end
