# frozen_string_literal: true

module DiscussionBridge
  # SQL work and source observation share the publisher's transaction. Redis is
  # only a wake-up mechanism; a retained policy cursor can resume without it.
  module PublicationWorkProducer
    BATCH_SIZE = 32

    def self.start!(policy)
      previous = DiscussionBridgePolicyProduction.find_by(destination_policy_id: policy.id)
      return previous if previous
      cut = DiscussionBridgeSourceInventoryEntry.where(content_connection_id: policy.content_connection_id).maximum(:id) || 0
      cursor = DiscussionBridgePolicyProduction.create!(destination_policy: policy, cut: cut, complete: cut.zero?)
      DB.after_commit { Jobs.enqueue(:discussion_bridge_produce_publication_work, production_id: cursor.id) } unless cursor.complete
      cursor
    end

    def self.observe!(connection, entry)
      return unless SourceRevocationProducer.enabled?
      DiscussionBridgeDestinationPolicy.current(connection).each do |policy|
        produce!(connection: connection, entry: entry, policy: policy)
      end
    end

    def self.resume!(production_id)
      cursor = DiscussionBridgePolicyProduction.find(production_id)
      connection = cursor.destination_policy.content_connection
      connection.with_lock do
        cursor.lock!
        return if cursor.complete || !SourceRevocationProducer.enabled? || !connection.enabled || !connection.allows_direction?("from_discourse")
        policy = cursor.destination_policy
        current = DiscussionBridgeDestinationPolicy.current(connection).find_by(destination_policy_id: policy.destination_policy_id)
        unless current&.id == policy.id
          cursor.update!(complete: true)
          return
        end
        entries = DiscussionBridgeSourceInventoryEntry.where(content_connection_id: connection.id)
          .where("id > ? AND id <= ?", cursor.position, cursor.cut).order(:id).limit(BATCH_SIZE).to_a
        entries.each do |entry|
          # The fixed cut is an enumeration, not permission to publish an old
          # observation after a newer source revision or withdrawal.
          latest = DiscussionBridgeSourceInventoryEntry.where(content_binding_id: entry.content_binding_id).order(id: :desc).first
          produce!(connection: connection, entry: latest, policy: policy)
        end
        position = entries.last&.id || cursor.cut
        complete = !DiscussionBridgeSourceInventoryEntry.where(content_connection_id: connection.id)
          .where("id > ? AND id <= ?", position, cursor.cut).exists?
        cursor.update!(position: position, complete: complete)
        DB.after_commit { Jobs.enqueue(:discussion_bridge_produce_publication_work, production_id: cursor.id) } unless complete
      end
    end

    # Caller owns the connection lock. Preserve the source association; the new
    # independent destination is NOT another baseline presentation binding.
    def self.produce!(connection:, entry:, policy:)
      return unless entry && connection.enabled && connection.allows_direction?("from_discourse")
      record = entry.bridge_record
      topic = Topic.with_deleted.lock.find_by(id: record.topic_id)
      record.lock!
      binding = entry.content_binding
      binding.lock!
      return unless eligible?(connection, entry, record, binding, topic)
      capture = entry.native_source_revision
      DestinationPolicy.validate!(connection, policy.definition)
      raise AdapterRequestBoundary::Error.new("reconciliation_required") unless policy.content_connection_id == connection.id &&
        policy.catalog_revision.content_connection_id == connection.id && policy.catalog_revision.platform_profile == policy.platform_profile &&
        policy.definition["catalog_revision"] == policy.catalog_revision.public_id && policy.definition["profile"] == policy.platform_profile

      destination = DiscussionBridgePublicationDestination.find_or_create_by!(content_connection_id: connection.id,
        destination_policy_id: policy.destination_policy_id, resource_id: record.resource_id) do |value|
        value.bridge_record = record
        value.content_binding = binding
      end
      destination.lock!
      unless destination.bridge_record_id == record.id && destination.content_binding_id == binding.id
        raise AdapterRequestBoundary::Error.new("identity_conflict")
      end
      identity = NativeSourceRevisionCapture.fingerprint("destination_id" => destination.id, "entry_id" => entry.id, "policy_id" => policy.id)
      existing = DiscussionBridgePublicationWork.find_by(identity_digest: identity)
      if existing
        PublicationWork.verify!(existing)
        return existing
      end
      previous = destination.desired_work
      context = resolve(connection, entry, capture, policy, destination)
      state = "available"
      begin
        DestinationPolicy.availability!(policy.definition, PlatformCatalog.current(connection, policy.platform_profile))
      rescue AdapterRequestBoundary::Error => error
        raise unless error.error_code == "policy_denied"
        state = "operator_attention"
      end
      work = DiscussionBridgePublicationWork.create!(publication_destination: destination, source_inventory_entry: entry,
        destination_policy: policy, public_id: "dbw_#{SecureRandom.hex(16)}", identity_digest: identity,
        context: context, context_digest: NativeSourceRevisionCapture.fingerprint(context), state: state,
        destination_mode: PublicationAcknowledgement.profile_mode!(policy.platform_profile))
      if previous && %w[available retry_wait operator_attention].include?(previous.state)
        previous.update!(state: "superseded")
      end
      destination.update!(desired_work: work)
      work
    end

    def self.eligible?(connection, entry, record, binding, topic)
      return false unless topic && !topic.deleted_at && !topic.private_message? && Guardian.new.can_see?(topic) &&
        record.direction == "from_discourse" && connection.allows_lane?(record.lane) && binding.state == "active" &&
        binding.role == "presentation" && binding.native_materialization && connection.allows_origin?(binding.canonical_url)
      unless entry.content_connection_id == connection.id && entry.bridge_record_id == record.id &&
          binding.content_connection_id == connection.id && binding.bridge_record_id == record.id &&
          entry.resource_id == record.resource_id && entry.binding_public_id == binding.public_id &&
          entry.canonical_url == binding.canonical_url && entry.topic_id == topic.id && entry.lane == record.lane &&
          SourceInventoryObservation.context_digest(entry.attributes) == entry.context_digest
        raise AdapterRequestBoundary::Error.new("reconciliation_required")
      end
      capture = entry.native_source_revision
      unless capture.bridge_record_id == record.id && capture.revision == record.source_revision &&
          capture.sequence == record.source_revision_sequence && NativeSourceRevisionCapture.retained?(record)
        raise AdapterRequestBoundary::Error.new("reconciliation_required")
      end
      notice = DiscussionBridgeSourceRevocation.where(content_binding_id: binding.id).order(id: :desc).first
      if notice
        SourceRevocationProducer.verify!(notice)
        return false if notice.source_revision_sequence >= capture.sequence || !notice.restorable ||
          %w[source_deleted source_unpublished scope_removed].exclude?(notice.reason)
      end
      Post.unscoped.where(topic_id: topic.id, post_number: 1, deleted_at: nil, id: capture.metadata.fetch("post_id")).exists?
    end

    def self.resolve(connection, entry, capture, policy, destination)
      definition = policy.definition
      container = policy.catalog_revision.catalog_items.find_by!(segment_type: "containers",
        item_id: definition.fetch("container_mapping").fetch("destination")).value
      terms = (capture.metadata.fetch("categories") + capture.metadata.fetch("tags")).map do |item|
        item["source_category_id"] || item["source_tag_id"]
      end
      taxonomy = Array(definition.fetch("taxonomy_mapping")["items"]).filter_map do |item|
        { "source_id" => item.fetch("source"), "destination_id" => item.fetch("destination") } if terms.include?(item.fetch("source"))
      end
      author = definition.fetch("author_mapping")
      source_author = capture.metadata.fetch("source_authors").first&.fetch("source_author_id")
      mapped = Array(author["items"]).find { |item| item["source"] == source_author }&.fetch("destination") || author["destination_id"]
      # An unissued predecessor is not evidence of a native publication. Keep
      # publish until an earlier attempt was actually issued; do not invent ACK.
      issued = DiscussionBridgeWorkIssue.where(publication_work_id: DiscussionBridgePublicationWork
        .where(publication_destination_id: destination.id).select(:id)).exists?
      action = issued ? "update" : "publish"
      values = { "resource_id" => entry.resource_id, "connection_id" => connection.public_id, "action" => action,
        "source_revision" => capture.revision, "source_revision_sequence" => capture.sequence,
        "policy_revision" => policy.policy_revision, "destination_policy_id" => policy.destination_policy_id,
        "catalog_revision" => policy.catalog_revision.public_id, "presentation_mode" => definition.fetch("presentation_mode"),
        "resolved_container" => container.slice("id", "kind"), "resolved_taxonomy" => taxonomy,
        "resolved_author" => { "mode" => author.fetch("mode"), "destination_id" => mapped },
        "native_limit_policy" => definition.fetch("native_limit_policy").deep_dup }
      { "work" => values, "policy_definition" => definition.deep_dup,
        "source_context_digest" => entry.context_digest, "source_fingerprint" => capture.fingerprint,
        "scope_revision" => SourceConnectionScope.revision(connection), "platform_profile" => policy.platform_profile }
    end
  end
end
