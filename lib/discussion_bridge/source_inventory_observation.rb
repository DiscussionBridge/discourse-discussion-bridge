# frozen_string_literal: true

module DiscussionBridge
  # The publication/update caller owns connection/topic/record locks and its
  # transaction. Observe one exact association; never populate history on GET.
  class SourceInventoryObservation
    FIELDS = %w[content_connection_id bridge_record_id content_binding_id native_source_revision_id
                resource_id topic_id binding_public_id canonical_url lane].freeze

    def self.call(connection:, record:, binding:, capture:)
      unless capture.bridge_record_id == record.id && binding.bridge_record_id == record.id &&
          binding.content_connection_id == connection.id && binding.role == "presentation" &&
          binding.state == "active" && (SourceRevisionTransport::METADATA_FIELDS - capture.metadata.keys).empty?
        raise ArgumentError, "source inventory context requires reconciliation"
      end
      attributes = { "content_connection_id" => connection.id, "bridge_record_id" => record.id,
        "content_binding_id" => binding.id, "native_source_revision_id" => capture.id,
        "resource_id" => record.resource_id, "topic_id" => record.topic_id,
        "binding_public_id" => binding.public_id, "canonical_url" => binding.canonical_url, "lane" => record.lane }
      digest = context_digest(attributes)
      last = DiscussionBridgeSourceInventoryEntry.where(content_connection_id: connection.id,
        bridge_record_id: record.id).order(id: :desc).first
      return last if last && last.context_digest == digest && context_digest(last.attributes) == digest

      entry = DiscussionBridgeSourceInventoryEntry.create!(attributes.merge(context_digest: digest, observed_at: Time.now.utc))
      PublicationWorkProducer.observe!(connection, entry)
      entry
    end

    def self.context_digest(attributes)
      NativeSourceRevisionCapture.fingerprint(attributes.slice(*FIELDS))
    end
  end
end
