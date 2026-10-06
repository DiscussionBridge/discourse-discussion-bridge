# frozen_string_literal: true

module DiscussionBridge
  class SourcePublicationLifecycle
    BATCH_SIZE = 100

    def self.enqueue_topic(topic_id)
      return false unless authorized_records(topic_id: topic_id).exists?

      Jobs.enqueue(:discussion_bridge_reconcile_source_topic, topic_id: topic_id)
      true
    end

    def self.reconcile_topic!(topic_id)
      authorized_records(topic_id: topic_id).includes(
        content_bindings: :content_connection,
      ).find_each do |record|
        connections_for(record).each do |connection|
          SourceRevocationRegistry.reconcile_record!(record: record, connection: connection)
        end
      end
    end

    def self.reconcile_connection!(connection_id, after_record_id: 0)
      connection = DiscussionBridgeContentConnection.find_by(id: connection_id)
      return false unless connection

      record_ids = DiscussionBridgeBridgeRecord.joins(:content_bindings).where(
        direction: "from_discourse",
        discussion_bridge_content_bindings: {
          content_connection_id: connection.id,
          role: "presentation",
          state: "active",
        },
      ).where("discussion_bridge_bridge_records.id > ?", after_record_id)
        .order(:id).distinct.limit(BATCH_SIZE + 1).pluck(:id)
      record_ids.first(BATCH_SIZE).each do |record_id|
        record = DiscussionBridgeBridgeRecord.find_by(id: record_id)
        SourceRevocationRegistry.reconcile_record!(record: record, connection: connection) if record
      end
      if record_ids.length > BATCH_SIZE
        Jobs.enqueue(
          :discussion_bridge_reconcile_source_connection,
          connection_id: connection.id,
          after_record_id: record_ids.fetch(BATCH_SIZE - 1),
        )
      end
      true
    end

    def self.enqueue_category(category_id, after_topic_id: 0)
      topic_ids = authorized_records
        .joins(:topic)
        .where(topics: { category_id: category_id })
        .where("discussion_bridge_bridge_records.topic_id > ?", after_topic_id)
        .order(:topic_id).distinct.limit(BATCH_SIZE + 1).pluck(:topic_id)
      topic_ids.first(BATCH_SIZE).each { |topic_id| enqueue_topic(topic_id) }
      return if topic_ids.length <= BATCH_SIZE

      Jobs.enqueue(
        :discussion_bridge_reconcile_source_category,
        category_id: category_id,
        after_topic_id: topic_ids.fetch(BATCH_SIZE - 1),
      )
    end

    def self.authorized_records(topic_id: nil)
      scope = DiscussionBridgeBridgeRecord.joins(
        content_bindings: :content_connection,
      ).where(
        direction: "from_discourse",
        discussion_bridge_content_bindings: {
          role: "presentation",
          state: "active",
        },
        discussion_bridge_content_connections: { enabled: true },
      ).where(
        "discussion_bridge_content_connections.allowed_directions @> ?::jsonb",
        ["from_discourse"].to_json,
      ).where(
        "jsonb_array_length(discussion_bridge_content_connections.destination_policies) > 0",
      ).distinct
      topic_id ? scope.where(topic_id: topic_id) : scope
    end
    private_class_method :authorized_records

    def self.connections_for(record)
      record.content_bindings.filter_map do |binding|
        next unless binding.role == "presentation" && binding.state == "active"

        connection = binding.content_connection
        next unless connection.enabled && connection.allows_direction?("from_discourse") &&
          connection.allows_lane?(record.lane) && connection.allows_origin?(binding.canonical_url) &&
          ConnectionCapability.publication_active?(connection)

        connection
      end
    end
    private_class_method :connections_for
  end
end
