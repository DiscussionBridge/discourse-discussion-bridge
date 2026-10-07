# frozen_string_literal: true

module DiscussionBridge
  # Refresh only previously observed, explicitly authorized native publications.
  # Current source state is rechecked under the same locks as native capture;
  # queued callbacks are not a license to create publications or edit posts.
  class SourceRevisionProducer
    BATCH_SIZE = 100

    def self.enqueue(selector)
      return unless SourceRevocationProducer.enabled?
      SourceRevocationProducer.validate_selector!(selector)
      cut = SourceRevocationProducer.bindings(selector).order(id: :desc).limit(1).pick(:id)
      return unless cut
      Jobs.enqueue(:discussion_bridge_capture_source_revisions, **selector.symbolize_keys, cut: cut, position: 0)
    end

    def self.call(binding_id:)
      return unless SourceRevocationProducer.enabled?
      owner = DiscussionBridgeContentBinding.where(id: binding_id).pick(:content_connection_id)
      return unless owner
      connection = DiscussionBridgeContentConnection.find(owner)
      connection.with_lock do
        return unless SourceRevocationProducer.enabled? && connection.enabled && connection.allows_direction?("from_discourse")
        binding = DiscussionBridgeContentBinding.find(binding_id)
        record = DiscussionBridgeBridgeRecord.find(binding.bridge_record_id)
        topic = Topic.with_deleted.lock.find_by(id: record.topic_id)
        record.lock!
        return unless topic && !topic.deleted_at && !topic.private_message? && Guardian.new.can_see?(topic) &&
          binding.content_connection_id == connection.id && binding.role == "presentation" && binding.state == "active" &&
          record.direction == "from_discourse" && connection.allows_lane?(record.lane) && connection.allows_origin?(binding.canonical_url)
        binding.lock!
        refresh(connection: connection, topic: topic, record: record, binding: binding)
      end
    end

    # Caller owns the connection/topic/record/binding locks and transaction.
    # Also used by explicit re-publication so it cannot replay a withdrawn revision.
    def self.refresh(connection:, topic:, record:, binding:)
      entry = DiscussionBridgeSourceInventoryEntry.where(content_binding_id: binding.id).order(id: :desc).first
      return unless entry
      unless SourceInventoryObservation.context_digest(entry.attributes) == entry.context_digest &&
          entry.content_connection_id == connection.id && entry.bridge_record_id == record.id &&
          entry.resource_id == record.resource_id && entry.binding_public_id == binding.public_id &&
          entry.canonical_url == binding.canonical_url && entry.topic_id == record.topic_id && entry.lane == record.lane
        raise ArgumentError, "source update context requires reconciliation"
      end
      post_identity = Post.unscoped.lock.where(topic_id: topic.id, post_number: 1).pick(:id, :deleted_at)
      return unless post_identity && !post_identity.last
      observed_capture = DiscussionBridgeNativeSourceRevision.where(id: entry.native_source_revision_id)
        .pick(:bridge_record_id, :metadata, :fingerprint)
      unless observed_capture && observed_capture.first == record.id &&
          observed_capture[1]["post_id"] == post_identity.first &&
          NativeSourceRevisionCapture.fingerprint(observed_capture[1]) == observed_capture.last
        raise ArgumentError, "source update revision requires reconciliation"
      end
      notice = DiscussionBridgeSourceRevocation.where(content_binding_id: binding.id).order(id: :desc).first
      if notice
        SourceRevocationProducer.verify!(notice)
        # Native eligibility does not clear an operator/policy hold or recreate
        # an identity whose original source was physically removed.
        return unless notice.restorable && %w[source_deleted source_unpublished scope_removed].include?(notice.reason)
      end
      capture = NativeSourceRevisionCapture.call(record: record, topic: topic, restoration: notice)
      SourceInventoryObservation.call(connection: connection, record: record, binding: binding, capture: capture)
      capture
    end
  end
end
