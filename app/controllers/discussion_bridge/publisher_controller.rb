# frozen_string_literal: true

module ::DiscussionBridge
  class PublisherController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    before_action :ensure_staff
    before_action :ensure_publisher_enabled

    def overview
      render json: {
        product: {
          name: "DiscussionBridge",
          version: DiscussionBridge::VERSION,
          ready: readiness_blockers.empty?,
          blockers: readiness_blockers,
        },
        connection: {
          receiver_url: SiteSetting.discussion_bridge_publisher_receiver_url,
          connection_id: SiteSetting.discussion_bridge_publisher_connection_id,
          lane: SiteSetting.discussion_bridge_publisher_lane,
          import_category_id: SiteSetting.discussion_bridge_publisher_import_category_id.to_i,
          secret: readiness_blockers.exclude?("secret_file"),
        },
        metrics: {
          published_topics: TopicCustomField.where(name: Publisher::RESOURCE_ID_FIELD).count,
          imported_topics: TopicCustomField.where(name: Publisher::SOURCE_RESOURCE_ID_FIELD).count,
          failed_topics: TopicCustomField.where(name: Publisher::PUBLISH_STATE_FIELD).where("value LIKE ?", "failed:%").count,
        },
        recent_topics: recent_topics,
      }
    end

    def publish_topic
      topic = Topic.find(params.require(:topic_id))
      guardian.ensure_can_see!(topic)
      Jobs.enqueue(:discussion_bridge_publisher_deliver, topic_id: topic.id)
      render json: { queued: true, topic_id: topic.id }
    end

    def topic_status
      topic = Topic.find(params.require(:topic_id))
      guardian.ensure_can_see!(topic)
      render json: {
        topic_id: topic.id,
        title: topic.title,
        topic_url: topic.url,
        state: topic.custom_fields[Publisher::PUBLISH_STATE_FIELD],
        resource_id: topic.custom_fields[Publisher::RESOURCE_ID_FIELD],
        remote_topic_id: topic.custom_fields[Publisher::REMOTE_TOPIC_ID_FIELD]&.to_i,
        remote_topic_url: topic.custom_fields[Publisher::REMOTE_TOPIC_URL_FIELD],
        attempts: topic.custom_fields[Publisher::ATTEMPTS_FIELD].to_i,
        correlation_id: topic.custom_fields[Publisher::CORRELATION_ID_FIELD],
        source_resource_id: topic.custom_fields[Publisher::SOURCE_RESOURCE_ID_FIELD],
      }
    end

    def import_record
      topic = Publisher::Importer.new(user: current_user, resource_id: params.require(:resource_id)).call
      render json: { imported: true, topic_id: topic.id, topic_url: topic.url }
    rescue Publisher::Importer::Error => error
      render json: { errors: [error.message] }, status: :unprocessable_entity
    end

    private

    def readiness_blockers
      @readiness_blockers ||= begin
        blockers = []
        blockers << "receiver_url" if SiteSetting.discussion_bridge_publisher_receiver_url.blank?
        blockers << "connection_id" unless Publisher::Client::CONNECTION_ID_PATTERN.match?(SiteSetting.discussion_bridge_publisher_connection_id.to_s)
        blockers << "lane" if SiteSetting.discussion_bridge_publisher_lane.blank?
        begin
          Publisher::Client.new
        rescue Publisher::Client::Error => error
          blockers << (error.message.include?("secret") ? "secret_file" : error.message)
        end
        blockers.uniq
      end
    end

    def recent_topics
      TopicCustomField
        .where(name: Publisher::PUBLISH_STATE_FIELD)
        .order(id: :desc)
        .limit(20)
        .filter_map do |field|
          topic = field.topic
          next if topic.blank? || topic.deleted_at.present?

          {
            topic_id: topic.id,
            title: topic.title,
            topic_url: topic.url,
            state: field.value,
            resource_id: topic.custom_fields[Publisher::RESOURCE_ID_FIELD] || topic.custom_fields[Publisher::SOURCE_RESOURCE_ID_FIELD],
            remote_topic_id: topic.custom_fields[Publisher::REMOTE_TOPIC_ID_FIELD]&.to_i,
            remote_topic_url: topic.custom_fields[Publisher::REMOTE_TOPIC_URL_FIELD],
            attempts: topic.custom_fields[Publisher::ATTEMPTS_FIELD].to_i,
          }
        end
    end

    def ensure_staff
      raise Discourse::InvalidAccess unless current_user&.staff?
    end

    def ensure_publisher_enabled
      raise Discourse::NotFound unless SiteSetting.discussion_bridge_publisher_enabled
    end
  end
end
