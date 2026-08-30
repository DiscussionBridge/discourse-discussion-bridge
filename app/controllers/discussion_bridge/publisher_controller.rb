# frozen_string_literal: true

module ::DiscussionBridge
  class PublisherController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    before_action :ensure_staff
    before_action :ensure_publisher_enabled

    def overview
      connections = available_connections
      render json: {
        product: {
          name: "DiscussionBridge",
          version: DiscussionBridge::VERSION,
          ready: readiness_blockers(connections).empty?,
          blockers: readiness_blockers(connections),
        },
        connections: connections.map { |connection| connection_payload(connection) },
        metrics: {
          published_topics: from_discourse_records.distinct.count(:topic_id),
          presentations: from_discourse_records.count,
          connected_platforms: connections.map(&:platform).uniq.count,
        },
        recent_records: recent_records,
      }
    end

    def publish_topic
      input = params.require(:publication)
      result = FromDiscourseRecordCreator.call(
        user: current_user,
        connection_id: input.fetch(:content_connection_id),
        topic_id: params.require(:topic_id),
        external_id: input.fetch(:external_id),
        canonical_url: input.fetch(:canonical_url),
      )
      render json: publication_payload(result.record).merge(outcome: result.outcome),
             status: result.outcome == "created" ? :created : :ok
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    def topic_status
      topic = Topic.find(params.require(:topic_id))
      guardian.ensure_can_see!(topic)
      render json: {
        topic_id: topic.id,
        title: topic.title,
        topic_url: topic.url,
        publications: from_discourse_records.where(topic_id: topic.id).order(:id).map do |record|
          publication_payload(record)
        end,
      }
    end

    private

    def available_connections
      @available_connections ||= DiscussionBridgeContentConnection
        .where(enabled: true)
        .order(:platform, :name, :id)
        .select { |connection| connection.allows_direction?("from_discourse") }
    end

    def from_discourse_records
      DiscussionBridgeBridgeRecord.where(direction: "from_discourse")
    end

    def readiness_blockers(connections)
      blockers = []
      blockers << "plugin_disabled" unless SiteSetting.discussion_bridge_enabled
      blockers << "endpoint_disabled" unless SiteSetting.discussion_bridge_endpoint_enabled
      blockers << "from_discourse_connection" if connections.empty?
      blockers
    end

    def connection_payload(connection)
      {
        id: connection.id,
        public_id: connection.public_id,
        name: connection.name,
        platform: connection.platform,
        allowed_origins: connection.allowed_origins,
        author_username: connection.effective_author&.username,
      }
    end

    def publication_payload(record)
      binding = record.active_binding("presentation")
      {
        resource_id: record.resource_id,
        state: record.state,
        topic_id: record.topic_id,
        title: record.title,
        topic_url: record.topic&.url,
        connection_id: binding&.content_connection_id,
        connection_name: binding&.content_connection&.name,
        platform: binding&.content_connection&.platform,
        external_id: binding&.external_id,
        canonical_url: binding&.canonical_url,
      }
    end

    def recent_records
      from_discourse_records.includes(:topic, content_bindings: :content_connection)
        .order(updated_at: :desc, id: :desc).limit(20).map { |record| publication_payload(record) }
    end

    def ensure_staff
      raise Discourse::InvalidAccess unless current_user&.staff?
    end

    def ensure_publisher_enabled
      raise Discourse::NotFound unless SiteSetting.discussion_bridge_publisher_enabled
    end
  end
end
