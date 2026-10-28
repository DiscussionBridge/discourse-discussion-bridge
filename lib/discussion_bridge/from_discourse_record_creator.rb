# frozen_string_literal: true

require "securerandom"

module DiscussionBridge
  # Native publishing uses the same current source/mapping engine as a connection
  # request. It never creates a detached record that later requires adoption.
  class FromDiscourseRecordCreator
    Result = Data.define(:record, :outcome)

    def self.call(user:, connection_id:, topic_id:, external_id:, canonical_url:, lane: nil,
                  presentation_mode: :unchanged)
      raise Discourse::InvalidAccess unless user&.staff?
      result = nil
      DiscussionBridgeContentConnection.transaction do
        connection = DiscussionBridgeContentConnection.lock.find(connection_id)
        configuration = CmsConfiguration.current!(connection, require_enabled: true)
        policy = configuration.fetch("policy")
        selected_lane = configuration.fetch("publication_lane")
        unless lane.nil? || lane.to_s.empty? || lane.to_s == selected_lane
          CmsProtocol.reject!("scope_denied")
        end
        unless presentation_mode == :unchanged || presentation_mode == policy.fetch("presentation_mode")
          CmsProtocol.reject!("presentation_unsupported")
        end
        topic = Topic.lock.find(topic_id)
        raise Discourse::InvalidAccess unless Guardian.new(user).can_see?(topic)
        CmsProtocol.reject!("source_ineligible") unless CmsConfiguration.eligible?(topic, policy)
        CmsProtocol.validate!("OpaqueId", external_id)
        CmsConfiguration.destination_url!(connection, configuration, canonical_url)

        refresh = CmsSourceLifecycle.refresh(connection, topic.id)
        intent = refresh.source_intent
        CmsProtocol.reject!("source_ineligible") unless intent && intent.state == "active"
        source_revision = intent.current_source_revision
        CmsProtocol.reject!("revision_conflict") unless source_revision
        response = CmsMappingService.new(connection).prepare(
          {
            "mutation_id" => SecureRandom.uuid,
            "source_id" => intent.source_id,
            "source_revision" => source_revision,
            "external_id" => external_id,
            "canonical_url" => canonical_url,
            "policy_revision" => policy.fetch("policy_revision"),
          },
          native_actor: user,
        )
        mapping = DiscussionBridgeCmsMapping.find_by!(
          content_connection_id: connection.id,
          mapping_id: response.body.fetch("mapping_id"),
        )
        result = Result.new(record: mapping.content_binding.bridge_record,
                            outcome: response.status == 201 ? "created" : "resolved")
      end
      result
    end
  end
end