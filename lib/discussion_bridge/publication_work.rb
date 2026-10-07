# frozen_string_literal: true

module DiscussionBridge
  module PublicationWork
    MAINTENANCE_LIMIT = 100
    MAX_ITEM_BYTES = 131_072
    CONTEXT_FIELDS = %w[work policy_definition source_context_digest source_fingerprint scope_revision platform_profile].freeze

    def self.verify!(work)
      destination = work.publication_destination
      entry = work.source_inventory_entry
      policy = work.destination_policy
      capture = DiscussionBridgeNativeSourceRevision.select(:id, :bridge_record_id, :revision, :sequence, :metadata, :fingerprint)
        .find(entry.native_source_revision_id)
      value = work.context
      identity = NativeSourceRevisionCapture.fingerprint("destination_id" => destination.id, "entry_id" => entry.id, "policy_id" => policy.id)
      unless work.identity_digest == identity && work.context_digest == NativeSourceRevisionCapture.fingerprint(value) &&
          work.destination_mode == PublicationAcknowledgement.profile_mode!(value["platform_profile"]) &&
          (value.keys - CONTEXT_FIELDS).empty? && (CONTEXT_FIELDS - value.keys).empty? &&
          value["policy_definition"] == policy.definition && value["source_context_digest"] == entry.context_digest &&
          SourceInventoryObservation.context_digest(entry.attributes) == entry.context_digest &&
          value["source_fingerprint"] == capture.fingerprint && NativeSourceRevisionCapture.fingerprint(capture.metadata) == capture.fingerprint &&
          destination.content_connection_id == entry.content_connection_id && destination.bridge_record_id == entry.bridge_record_id &&
          destination.content_binding_id == entry.content_binding_id && destination.resource_id == entry.resource_id &&
          policy.content_connection_id == entry.content_connection_id && destination.destination_policy_id == policy.destination_policy_id &&
          capture.bridge_record_id == entry.bridge_record_id && value["platform_profile"] == policy.platform_profile &&
          value.fetch("work").slice("resource_id", "connection_id", "source_revision", "source_revision_sequence",
            "policy_revision", "destination_policy_id", "catalog_revision") == {
            "resource_id" => entry.resource_id, "connection_id" => destination.content_connection.public_id,
            "source_revision" => capture.revision, "source_revision_sequence" => capture.sequence,
            "policy_revision" => policy.policy_revision, "destination_policy_id" => policy.destination_policy_id,
            "catalog_revision" => policy.catalog_revision.public_id,
          }
        raise AdapterRequestBoundary::Error.new("reconciliation_required")
      end
      work
    end

    def self.connection!(connection)
      DestinationPolicy.fail_with("temporarily_unavailable") unless SourceRevocationProducer.enabled?
      DestinationPolicy.fail_with("direction_denied") unless connection.enabled && connection.allows_direction?("from_discourse")
    end

    def self.claim_request!(value)
      DestinationPolicy.object!(value, %w[worker_id correlation_id], %w[maximum_items requested_lease_seconds])
      DestinationPolicy.string!(value["worker_id"], 200)
      %w[maximum_items requested_lease_seconds].each do |field|
        next unless value.key?(field)
        maximum = field == "maximum_items" ? 32 : 3600
        DestinationPolicy.fail_with unless value[field].is_a?(Integer) && value[field].between?(1, maximum)
      end
    end

    # The controller holds/rechecks the authenticated connection lock. Each
    # destination is locked separately; its active item prevents a newer native
    # mutation. Traversal, expiry repair and response construction are bounded.
    def self.claim!(connection, request)
      connection!(connection)
      claim_request!(request)
      maintain!(connection)
      maximum = request.fetch("maximum_items", 1)
      seconds = request.fetch("requested_lease_seconds", 300)
      eligible = []
      scope = DiscussionBridgePublicationDestination.where(content_connection_id: connection.id, active_work_id: nil)
        .joins(:desired_work).where(discussion_bridge_publication_works: { state: "available" })
      scope.order("discussion_bridge_publication_works.id").limit(MAINTENANCE_LIMIT).each do |destination|
        destination.lock!
        work = destination.desired_work
        work.lock!
        verify!(work)
        entry = work.source_inventory_entry
        topic = Topic.with_deleted.lock.find_by(id: entry.topic_id)
        record = entry.bridge_record
        record.lock!
        binding = entry.content_binding
        binding.lock!
        policy = work.destination_policy
        current = DiscussionBridgeDestinationPolicy.current(connection).find_by(destination_policy_id: destination.destination_policy_id)
        if current&.id != policy.id
          work.update!(state: "superseded")
          next
        end
        unless PublicationWorkProducer.eligible?(connection, entry, record, binding, topic) &&
            work.context["scope_revision"] == SourceConnectionScope.revision(connection)
          work.update!(state: "operator_attention")
          next
        end
        begin
          DestinationPolicy.availability!(policy.definition, PlatformCatalog.current(connection, policy.platform_profile))
        rescue AdapterRequestBoundary::Error => error
          raise unless error.error_code == "policy_denied"
          work.update!(state: "operator_attention")
          next
        end
        eligible << [destination, work]
        break if eligible.size == maximum
      end
      # Sample once AFTER all blocking locks and authorization rechecks.
      now = Time.now.utc
      items = eligible.map do |destination, work|
        work.update!(state: "leased", lease_started_at: now, lease_expires_at: now + seconds,
          total_lease_seconds: seconds, worker_id: request.fetch("worker_id"), lease_token: SecureRandom.hex(32), stage_token: SecureRandom.hex(32))
        value = work.context.fetch("work").merge("work_id" => work.public_id, "lease_token" => work.lease_token,
          "stage_token" => work.stage_token, "lease_expires_at" => work.lease_expires_at.utc.iso8601(6),
          "attempt_count" => work.attempt_count, "retry_generation" => work.retry_generation,
          "correlation_id" => request.fetch("correlation_id"))
        DestinationPolicy.fail_with("integrity_failed") if JSON.generate(value).bytesize > MAX_ITEM_BYTES
        DiscussionBridgeWorkIssue.create!(publication_work: work, work: value.deep_dup, worker_id: work.worker_id, claimed_at: now)
        destination.update!(active_work: work)
        value
      end
      { "publication_work" => items, "claimed_at" => now.iso8601(6), "correlation_id" => request.fetch("correlation_id") }
    end

    def self.maintain!(connection)
      now = Time.now.utc
      DiscussionBridgePublicationDestination.where(content_connection_id: connection.id).joins(:active_work)
        .where(discussion_bridge_publication_works: { state: "leased" })
        .where("discussion_bridge_publication_works.lease_expires_at <= ?", now)
        .order("discussion_bridge_publication_works.lease_expires_at, discussion_bridge_publication_works.id")
        .limit(MAINTENANCE_LIMIT).each do |destination|
        destination.lock!
        work = destination.active_work
        work.lock!
        verify!(work)
        # Retain tokens/issue history. Reissuance creates new tokens; an expired
        # or superseded token cannot become a receipt for the next attempt.
        work.update!(state: destination.desired_work_id == work.id ? "available" : "superseded")
        destination.update!(active_work: nil)
      end
    end

    def self.renew!(connection, public_id, request)
      connection!(connection)
      DestinationPolicy.object!(request, %w[lease_token requested_lease_seconds correlation_id])
      token = request.fetch("lease_token")
      DestinationPolicy.fail_with unless token.is_a?(String) && /\A[a-f0-9]{64}\z/.match?(token)
      seconds = request.fetch("requested_lease_seconds")
      DestinationPolicy.fail_with unless seconds.is_a?(Integer) && seconds.between?(1, 3600)
      work = DiscussionBridgePublicationWork.joins(:publication_destination)
        .where(discussion_bridge_publication_destinations: { content_connection_id: connection.id }).find_by!(public_id: public_id)
      destination = work.publication_destination
      destination.lock!
      work.lock!
      verify!(work)
      now = Time.now.utc
      DestinationPolicy.fail_with("work_superseded") if work.state == "superseded"
      DestinationPolicy.fail_with("lease_conflict") unless work.state == "leased" && destination.active_work_id == work.id &&
        ActiveSupport::SecurityUtils.secure_compare(work.lease_token.to_s, token)
      DestinationPolicy.fail_with("work_expired") if work.lease_expires_at <= now
      DestinationPolicy.fail_with("lease_limit_exceeded") if work.total_lease_seconds + seconds > 14_400
      # Renewal is additive to the original lease, not a new unbounded window.
      work.update!(lease_expires_at: work.lease_expires_at + seconds, total_lease_seconds: work.total_lease_seconds + seconds)
      { "work_id" => work.public_id, "lease_expires_at" => work.lease_expires_at.utc.iso8601(6),
        "total_lease_seconds" => work.total_lease_seconds, "correlation_id" => request.fetch("correlation_id") }
    end
  end
end
