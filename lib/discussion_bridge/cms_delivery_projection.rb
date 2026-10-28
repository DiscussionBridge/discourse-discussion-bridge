# frozen_string_literal: true

module DiscussionBridge
  module CmsDeliveryProjection
    # Retained delivery facts are readable even when adapter scope is revoked.
    # No receipt, lease token, failure detail or credential is serialized here.
    def self.call(mapping, work: nil)
      work ||= mapping.work_items.order(created_at: :desc, id: :desc).first
      connection = mapping.content_connection
      binding = mapping.content_binding
      topic = binding.bridge_record.topic
      scope_issue = nil
      configuration = nil
      begin
        configuration = CmsConfiguration.current!(connection, require_enabled: true)
        unless binding.state == "active" &&
                 binding.bridge_record.lane.to_s == configuration.fetch("publication_lane")
          CmsProtocol.reject!("scope_denied")
        end
        CmsConfiguration.destination_url!(connection, configuration, binding.canonical_url)
        CmsConfiguration.forum_name!
      rescue CmsProtocol::Error => error
        scope_issue = error.code
      end
      policy = configuration&.fetch("policy")
      eligible = policy && CmsConfiguration.eligible?(topic, policy)
      catalog_available =
        configuration && CmsCatalogAvailabilityLifecycle.publication_eligible?(
          connection, configuration: configuration, action: "publish_revision",
        )
      latest_verified =
        work&.state == "verified" && work.action == "publish_revision" &&
          work.source_revision == mapping.desired_source_revision &&
          mapping.publicly_verified_source_revision == mapping.desired_source_revision
      state =
        if work&.state == "verified" && work.action == "withdraw" &&
             mapping.mapping_state == "withdrawn"
          "withdrawal_verified"
        elsif latest_verified
          "publication_verified"
        elsif work&.state == "cancelled" && mapping.destination_native_id
          "withdrawal_attention"
        else
          work&.state || "unverified"
        end
      {
        "mapping_id" => mapping.mapping_id,
        "resource_id" => binding.bridge_record.resource_id,
        "topic_id" => topic&.id,
        "topic_title" => topic&.title || binding.bridge_record.title,
        "connection_id" => connection.public_id,
        "source_id" => mapping.source_id,
        "canonical_url" => binding.canonical_url,
        "destination_native_id" => mapping.destination_native_id,
        "mapping_state" => mapping.mapping_state,
        "publication_status" => state,
        "attention_required" =>
          mapping.mapping_state == "attention" || %w[attention withdrawal_attention].include?(state) ||
            (scope_issue.present? && mapping.destination_native_id.present?),
        "scope_available" => scope_issue.nil?,
        "scope_issue" => scope_issue,
        "source_eligible" => !!eligible,
        "publication_eligible" => scope_issue.nil? && !!eligible && !!catalog_available,
        "desired_source_revision" => mapping.desired_source_revision,
        "synchronized_source_revision" => mapping.synchronized_source_revision,
        "publicly_verified_source_revision" => mapping.publicly_verified_source_revision,
        "destination_native_revision" => mapping.destination_native_revision,
        "source_created_at" => CmsProtocol.instant(mapping.source_created_at),
        "source_updated_at" => CmsProtocol.instant(mapping.source_updated_at),
        "synchronized_at" => CmsProtocol.instant(mapping.synchronized_at),
        "publicly_verified_at" => CmsProtocol.instant(mapping.publicly_verified_at),
        "prepared_native_reconciliation_required" => mapping.prepared_transaction.present?,
        "attention_recovery" => CmsAttentionRecovery.new(connection).projection(mapping, work),
        "work" => work && {
          "work_id" => work.work_id,
          "action" => work.action,
          "state" => work.state,
          "source_revision" => work.source_revision,
          "policy_revision" => work.policy_revision,
          "attempt_cycle" => work.attempt_cycle,
          "attempt" => work.attempt,
          "attempt_ceiling" => 3,
          "lease_generation" => work.lease_generation,
          "retry_at" => CmsProtocol.instant(work.retry_at),
          "last_failure_code" =>
            CmsProtocol::ERRORS.key?(work.last_failure_code) ? work.last_failure_code : nil,
          "same_intent_hold" => work.same_intent_hold?,
        },
      }
    end
  end
end

