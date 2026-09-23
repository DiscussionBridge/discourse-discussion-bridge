# frozen_string_literal: true

module DiscussionBridge
  class PublicationSummary
    PENDING_STATES = %w[queued claimed retrying].freeze
    ATTENTION_STATES = %w[attention failed].freeze

    def self.call(topic)
      new(topic).call
    end

    def initialize(topic)
      @topic = topic
    end

    def call
      connection_ids = publication_connection_ids
      return nil if connection_ids.empty?

      work_by_connection = publication_work_items.index_by(&:content_connection_id)
      records = publication_records
      bindings = publication_bindings
      published_connection_ids = connection_ids.select do |connection_id|
        published_for_connection?(
          connection_id,
          work_by_connection[connection_id],
          records,
          bindings,
        )
      end
      pending = work_by_connection.values.count { |item| PENDING_STATES.include?(item.state) }
      attention = work_by_connection.values.count { |item| ATTENTION_STATES.include?(item.state) }
      published = published_connection_ids.length

      {
        state: summary_state(
          published: published,
          total: connection_ids.length,
          pending: pending,
          attention: attention,
        ),
        published: published,
        total: connection_ids.length,
        pending: pending,
        attention: attention,
      }
    end

    private

    def publication_connection_ids
      DiscussionBridgeContentConnection
        .where(enabled: true, forum_publication_enabled: true)
        .select { |connection| connection.allows_direction?("from_discourse") }
        .map(&:id)
    end

    def publication_work_items
      association = @topic.association(:discussion_bridge_publication_work_items)
      items = association.loaded? ? association.target : association.scope.to_a
      allowed = publication_connection_ids.to_set
      items.select { |item| allowed.include?(item.content_connection_id) }
    end

    def publication_records
      association = @topic.association(:discussion_bridge_bridge_records)
      records = if association.loaded?
        association.target
      else
        association.scope.to_a
      end
      records.select { |record| record.direction == "from_discourse" }
    end

    def publication_bindings
      association = @topic.association(:discussion_bridge_content_bindings)
      association.loaded? ? association.target : association.scope.to_a
    end

    def published_for_connection?(connection_id, work, records, bindings)
      return false if work&.state == "unpublished"
      return true if work&.state == "current"

      binding = bindings.find do |candidate|
        candidate.content_connection_id == connection_id &&
          candidate.role == "presentation" && candidate.state == "active"
      end
      record = records.find { |candidate| candidate.id == binding&.bridge_record_id }
      return false unless record
      return false if record.destination_state == "held"

      record.destination_state == "healthy" || record.destination_state.nil?
    end

    def summary_state(published:, total:, pending:, attention:)
      return "attention" if attention.positive?
      return "pending" if pending.positive?
      return "published" if published == total
      return "not_published" if published.zero?

      "partial"
    end
  end
end
