# frozen_string_literal: true

module DiscussionBridge
  module AdapterProtocolRecords
    def self.call(record, connection:)
      unless record.known_source_context?
        raise AdapterRequestBoundary::Error.new("reconciliation_required")
      end
      topic = record.topic
      unless topic && topic.deleted_at.nil? && topic.first_post && topic.first_post.deleted_at.nil?
        raise AdapterRequestBoundary::Error.new("reconciliation_required")
      end
      if record.direction == "from_discourse"
        unless Guardian.new.can_see?(topic) && !topic.private_message?
          raise AdapterRequestBoundary::Error.new("policy_denied")
        end
        unless NativeSourceRevisionCapture.retained?(record)
          raise AdapterRequestBoundary::Error.new("reconciliation_required")
        end
      end
      bindings = record.content_bindings.where(content_connection_id: connection.id, state: "active").map do |binding|
        unless binding.public_id && binding.presentation_mode && binding.content_disposition
          raise AdapterRequestBoundary::Error.new("reconciliation_required")
        end
        value = {
          binding_id: binding.public_id, connection_id: connection.public_id,
          role: binding.role, state: binding.state, external_id: binding.external_id,
          canonical_url: binding.canonical_url, presentation_mode: binding.presentation_mode,
          content_disposition: binding.content_disposition,
          deployment_state: "not_required", verification_state: "not_required",
        }
        if binding.applied_source_revision
          unless binding.publication_revision && binding.synchronized_at_raw
            raise AdapterRequestBoundary::Error.new("reconciliation_required")
          end
          value.merge!(applied_source_revision: binding.applied_source_revision,
                       publication_revision: binding.publication_revision,
                       synchronized_at: binding.synchronized_at_raw)
        end
        value[:read_more_url] = binding.read_more_url if binding.read_more_url
        value
      end
      {
        resource_id: record.resource_id, direction: record.direction, state: record.state,
        title: record.title, topic_id: record.topic_id, topic_url: topic.url,
        source_revision: record.source_revision, source_revision_sequence: record.source_revision_sequence,
        source_created_at: record.source_created_at_raw, source_updated_at: record.source_updated_at_raw,
        content_disposition: record.content_disposition, bindings: bindings,
      }
    end
  end
end
