# frozen_string_literal: true

module DiscussionBridge
  # Native callbacks enqueue only already-observed From-Discourse associations.
  # Workers check current state under the publication connection/record locks;
  # delayed jobs cannot revoke a newer, currently eligible source by inference.
  class SourceRevocationProducer
    BATCH_SIZE = 100
    SELECTORS = %w[topic_id category_id content_connection_id].freeze
    FIELDS = %w[content_connection_id bridge_record_id content_binding_id native_source_revision_id
                resource_id binding_public_id source_revision source_revision_sequence reason restorable].freeze

    def self.enabled?
      SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled &&
        SiteSetting.discussion_bridge_publisher_enabled
    end

    def self.enqueue(selector)
      return unless enabled?
      validate_selector!(selector)
      cut = bindings(selector).order(id: :desc).limit(1).pick(:id)
      return unless cut
      Jobs.enqueue(:discussion_bridge_record_source_revocations, **selector.symbolize_keys, cut: cut, position: 0)
    end

    def self.bindings(selector)
      relation = DiscussionBridgeContentBinding.joins(:bridge_record, :content_connection).where(
        role: "presentation", state: "active", discussion_bridge_bridge_records: { direction: "from_discourse" },
        discussion_bridge_content_connections: { enabled: true },
      ).where.not(public_id: nil).where(<<~SQL)
        EXISTS (SELECT 1 FROM discussion_bridge_source_inventory_entries observed
                WHERE observed.content_binding_id = discussion_bridge_content_bindings.id)
      SQL
      key, value = selector.to_a.sole
      case key.to_s
      when "topic_id"
        relation.where(discussion_bridge_bridge_records: { topic_id: value })
      when "category_id"
        relation.joins("INNER JOIN topics source_topic ON source_topic.id = discussion_bridge_bridge_records.topic_id")
          .where("source_topic.category_id = ?", value)
      when "content_connection_id"
        relation.where(content_connection_id: value)
      end
    end

    def self.validate_selector!(selector)
      unless selector.is_a?(Hash) && selector.size == 1 && SELECTORS.include?(selector.keys.sole.to_s) &&
          selector.values.sole.is_a?(Integer) && selector.values.sole.positive?
        raise ArgumentError, "invalid source withdrawal selector"
      end
    end

    def self.call(binding_id:)
      return unless enabled?
      owner = DiscussionBridgeContentBinding.where(id: binding_id).pick(:content_connection_id)
      return unless owner
      connection = DiscussionBridgeContentConnection.find(owner)
      connection.with_lock do
        return unless enabled? && connection.enabled
        binding = DiscussionBridgeContentBinding.find(binding_id)
        record = DiscussionBridgeBridgeRecord.find(binding.bridge_record_id)
        topic = Topic.with_deleted.lock.find_by(id: record.topic_id)
        record.lock!
        return unless binding.content_connection_id == connection.id && binding.role == "presentation" &&
          binding.state == "active" && record.direction == "from_discourse"
        binding.lock!
        post_identity = Post.unscoped.lock.where(topic_id: record.topic_id, post_number: 1).pick(:id, :deleted_at)
        reason = if !topic || topic.deleted_at || !post_identity || post_identity.last
          "source_deleted"
        elsif topic.private_message? || !Guardian.new.can_see?(topic)
          "source_unpublished"
        elsif !connection.allows_direction?("from_discourse") || !connection.allows_lane?(record.lane) ||
            !connection.allows_origin?(binding.canonical_url)
          "scope_removed"
        end
        return unless reason

        entry = DiscussionBridgeSourceInventoryEntry.where(content_binding_id: binding.id).order(id: :desc).first
        return unless entry
        unless SourceInventoryObservation.context_digest(entry.attributes) == entry.context_digest &&
            entry.content_connection_id == connection.id && entry.bridge_record_id == record.id &&
            entry.resource_id == record.resource_id && entry.binding_public_id == binding.public_id &&
            entry.canonical_url == binding.canonical_url && entry.topic_id == record.topic_id && entry.lane == record.lane &&
            record.known_source_context?
          raise ArgumentError, "source withdrawal context requires reconciliation"
        end
        capture = DiscussionBridgeNativeSourceRevision.select(:id, :bridge_record_id, :revision, :sequence, :fingerprint, :metadata)
          .find(entry.native_source_revision_id)
        same_post = !post_identity || capture.metadata["post_id"] == post_identity.first
        unless capture.bridge_record_id == record.id && capture.revision == record.source_revision &&
            capture.sequence == record.source_revision_sequence && capture.fingerprint == record.source_request_fingerprint &&
            NativeSourceRevisionCapture.fingerprint(capture.metadata) == capture.fingerprint && same_post
          raise ArgumentError, "source withdrawal revision requires reconciliation"
        end
        attributes = { "content_connection_id" => connection.id, "bridge_record_id" => record.id,
          "content_binding_id" => binding.id, "native_source_revision_id" => capture.id,
          "resource_id" => record.resource_id, "binding_public_id" => binding.public_id,
          "source_revision" => capture.revision, "source_revision_sequence" => capture.sequence,
          "reason" => reason, "restorable" => topic.present? && post_identity.present? }
        identity = NativeSourceRevisionCapture.fingerprint(attributes)
        existing = DiscussionBridgeSourceRevocation.find_by(identity_digest: identity)
        if existing
          verify!(existing)
          return existing
        end
        attributes.merge!("public_id" => "dbr_#{SecureRandom.hex(16)}", "identity_digest" => identity,
          "effective_at_raw" => Time.now.utc.iso8601(6))
        DiscussionBridgeSourceRevocation.create!(attributes.merge("context_digest" => context_digest(attributes)))
      end
    end

    def self.context_digest(attributes)
      NativeSourceRevisionCapture.fingerprint(attributes.slice(*(FIELDS + %w[public_id identity_digest effective_at_raw])))
    end

    def self.verify!(notice)
      capture_identity = DiscussionBridgeNativeSourceRevision.where(id: notice.native_source_revision_id)
        .pick(:bridge_record_id, :revision, :sequence)
      unless context_digest(notice.attributes) == notice.context_digest &&
          NativeSourceRevisionCapture.fingerprint(notice.attributes.slice(*FIELDS)) == notice.identity_digest &&
          notice.content_binding.content_connection_id == notice.content_connection_id &&
          notice.content_binding.bridge_record_id == notice.bridge_record_id &&
          notice.content_binding.public_id == notice.binding_public_id &&
          notice.bridge_record.direction == "from_discourse" && notice.bridge_record.resource_id == notice.resource_id &&
          capture_identity == [notice.bridge_record_id, notice.source_revision, notice.source_revision_sequence]
        raise AdapterRequestBoundary::Error.new("reconciliation_required")
      end
      BridgeRecordRequest.timestamp!(notice.effective_at_raw)
      notice
    end
  end
end
