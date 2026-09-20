# frozen_string_literal: true

module ::DiscussionBridge
  class PublisherController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    before_action :ensure_staff
    before_action :ensure_publisher_enabled

    def overview
      connections = available_connections
      work_counts = DiscussionBridgePublicationWorkItem.group(:state).count
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
          publication_work: DiscussionBridgePublicationWorkItem::STATES.index_with do |state|
            work_counts.fetch(state, 0)
          end,
        },
        recent_records: recent_records,
        publication_work: recent_publication_work,
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
        lane: input[:lane],
        native_materialization: native_materialization(input[:native_materialization]),
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

    def correct_presentation
      record = PresentationBindingCorrector.call(
        user: current_user,
        resource_id: params.require(:resource_id),
        canonical_url: params.require(:publication).fetch(:canonical_url),
      )
      render json: publication_payload(record).merge(outcome: "presentation_corrected")
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique,
           ActiveRecord::RecordNotFound, ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    def migrate_presentation_url
      input = params.require(:migration)
      result = PublicationUrlMigrator.call(
        user: current_user,
        resource_id: params.require(:resource_id),
        old_url: input.fetch(:old_url),
        new_url: input.fetch(:new_url),
        legacy_native_confirmation: input[:legacy_native_confirmation] == true ||
          input[:legacy_native_confirmation] == "true",
        platform_content_id: input[:platform_content_id],
      )
      render json: publication_payload(result.record).merge(
        outcome: result.outcome,
        redirect_status: result.redirect_status,
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique,
           ActiveRecord::RecordNotFound, ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    def retry_publication_work
      item = DiscussionBridgePublicationWorkItem.includes(:content_connection).find(params.require(:id))
      raise ArgumentError, "publication work is not retryable" unless item.state == "failed"
      raise ArgumentError, "publication connection is unavailable" unless
        DiscussionBridge::PublicationWorkQueue.publication_connection?(item.content_connection)

      item.with_lock do
        raise ArgumentError, "publication work is not retryable" unless item.state == "failed"
        item.update!(
          state: "queued",
          reason: "operator_retry",
          attempt_count: 0,
          available_at: Time.zone.now,
          claimed_at: nil,
          lease_token: nil,
          lease_expires_at: nil,
          completed_at: nil,
          last_error_code: nil,
          last_error_detail: nil,
        )
      end
      DiscussionBridge::PublicationAttentionNotifier.call(item.content_connection)
      render json: {
        outcome: "queued",
        publication_work: recent_publication_work.find { |row| row[:id] == item.id },
      }
    rescue ActiveRecord::RecordNotFound, ArgumentError => error
      render json: { errors: [error.message] }, status: :unprocessable_entity
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
      blockers << "publication_work_attention" if
        DiscussionBridgePublicationWorkItem.where(
          state: DiscussionBridgePublicationWorkItem::ATTENTION_STATES,
        ).exists?
      blockers
    end

    def connection_payload(connection)
      {
        id: connection.id,
        public_id: connection.public_id,
        name: connection.name,
        platform: connection.platform,
        allowed_origins: connection.allowed_origins,
        allowed_lanes: connection.allowed_lanes,
        author_username: connection.effective_author&.username,
        include_source_in_published_url: connection.include_source_in_published_url,
        publication_source_path: connection.publication_source_path,
      }
    end

    def publication_payload(record)
      binding = record.active_binding("presentation")
      work = binding && record.publication_work_items.find_by(
        content_connection_id: binding.content_connection_id,
      )
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
        lane: record.lane,
        native_materialization: binding&.native_materialization || false,
        delivery_state: work&.state || record.destination_state,
        delivery_reason: work&.reason || record.last_delivery_error_code,
        delivery_attempt_count: work&.attempt_count || record.delivery_attempt_count,
        last_delivery_attempt_at: record.last_delivery_attempt_at,
      }
    end

    def recent_records
      from_discourse_records.includes(:topic, :publication_work_items, content_bindings: :content_connection)
        .order(updated_at: :desc, id: :desc).limit(20).map { |record| publication_payload(record) }
    end

    def recent_publication_work
      DiscussionBridgePublicationWorkItem.includes(:content_connection, bridge_record: :topic)
        .order(updated_at: :desc, id: :desc).limit(50).map do |item|
        record = item.bridge_record
        {
          id: item.id,
          topic_id: item.topic_id,
          topic_url: record&.topic&.url || "/t/#{item.topic_id}",
          title: record&.title || Topic.with_deleted.where(id: item.topic_id).pick(:title),
          connection_name: item.content_connection.name,
          platform: item.content_connection.platform,
          action: item.action,
          state: item.state,
          reason: item.reason,
          attempt_count: item.attempt_count,
          available_at: item.available_at,
          claimed_at: item.claimed_at,
          lease_expires_at: item.lease_expires_at,
          completed_at: item.completed_at,
          last_error_code: item.last_error_code,
          last_error_detail: item.last_error_detail,
          canonical_url: record&.active_binding("presentation")&.canonical_url,
        }
      end
    end

    def native_materialization(value)
      return false if value.nil? || value == false || value == "false"
      return true if value == true || value == "true"

      raise ArgumentError, "invalid native_materialization"
    end

    def ensure_staff
      raise Discourse::InvalidAccess unless current_user&.staff?
    end

    def ensure_publisher_enabled
      raise Discourse::NotFound unless SiteSetting.discussion_bridge_publisher_enabled
    end
  end
end
