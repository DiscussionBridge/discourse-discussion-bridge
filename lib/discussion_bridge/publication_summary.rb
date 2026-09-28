# frozen_string_literal: true

module DiscussionBridge
  class PublicationSummary
    PENDING_STATES = %w[
      available
      leased
      retry_wait
      awaiting_deployment
      awaiting_verification
    ].freeze

    def self.call(topic)
      new(topic).call
    end

    def initialize(topic)
      @topic = topic
    end

    def call
      destinations = destination_states
      return nil if destinations.empty?

      published = destinations.count { |item| item == "published" }
      pending = destinations.count { |item| item == "pending" }
      attention = destinations.count { |item| item == "attention" }
      excluded = destinations.count { |item| item == "excluded" }
      {
        state: summary_state(
          total: destinations.length,
          published: published,
          pending: pending,
          attention: attention,
          excluded: excluded,
        ),
        published: published,
        total: destinations.length,
        pending: pending,
        attention: attention,
        excluded: excluded,
      }
    end

    private

    def destination_states
      records = DiscussionBridgeBridgeRecord.includes(
        :publication_works,
        content_bindings: :content_connection,
      ).where(direction: "from_discourse", topic_id: @topic.id)
      records.filter_map do |record|
        binding = record.content_bindings.find do |candidate|
          candidate.role == "presentation" && candidate.state == "active" &&
            candidate.content_connection.enabled &&
            candidate.content_connection.allows_direction?("from_discourse")
        end
        next unless binding
        if PublicationControl.excluded?(
          connection: binding.content_connection,
          topic_id: @topic.id,
        )
          next "excluded"
        end
        next "attention" if %w[attention failed migration].include?(record.state)

        work = record.publication_works
          .select { |item| item.content_connection_id == binding.content_connection_id }
          .max_by(&:id)
        work_state(work)
      end
    end

    def work_state(work)
      return "pending" unless work
      return "attention" if work.state == "operator_attention"
      return "pending" if PENDING_STATES.include?(work.state)
      return "not_published" if work.state == "superseded"
      return "not_published" if work.state == "acknowledged" && work.action == "unpublish"
      return "published" if work.state == "acknowledged"

      "pending"
    end

    def summary_state(total:, published:, pending:, attention:, excluded:)
      return "attention" if attention.positive?
      return "pending" if pending.positive?
      return "published" if published == total
      return "not_published" if published.zero? && excluded == total
      return "not_published" if published.zero?

      "partial"
    end
  end
end
