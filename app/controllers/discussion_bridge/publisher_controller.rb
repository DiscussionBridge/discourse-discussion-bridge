# frozen_string_literal: true

module ::DiscussionBridge
  class PublisherController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    before_action :ensure_staff
    before_action :ensure_administrator, only: [:overview]
    before_action :ensure_publisher_enabled

    rescue_from CmsProtocol::Error do |error|
      render json: { errors: [error.code] }, status: CmsProtocol::ERRORS.fetch(error.code).fetch("http")
    end

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
                 tracked_topics: from_discourse_records.distinct.count(:topic_id),
                 published_topics: verified_publications.distinct.count("discussion_bridge_bridge_records.topic_id"),
                 presentations: from_discourse_records.count,
                 connected_platforms: connections.map(&:platform).uniq.count,
               },
               recent_records: recent_records,
             }
    end

    def publish_topic
      input = params.require(:publication)
      result =
        FromDiscourseRecordCreator.call(
          user: current_user,
          connection_id: input.fetch(:content_connection_id),
          topic_id: params.require(:topic_id),
          external_id: input.fetch(:external_id),
          canonical_url: input.fetch(:canonical_url),
          lane: input[:lane],
          presentation_mode:
            input.key?(:presentation_mode) ? input[:presentation_mode] : :unchanged,
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
               publications:
                 from_discourse_records
                   .where(topic_id: topic.id)
                   .order(:id)
                   .map do |record| publication_payload(record) end,
             }
    end

    def correct_presentation
      result =
        PresentationBindingCorrector.call(
          user: current_user,
          resource_id: params.require(:resource_id),
          canonical_url: params.require(:publication).fetch(:canonical_url),
        )
      render json: publication_payload(result.record).merge(outcome: result.outcome)
    rescue ActiveRecord::RecordInvalid,
           ActiveRecord::RecordNotUnique,
           ActiveRecord::RecordNotFound,
           ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    private

    def available_connections
      @available_connections ||=
        DiscussionBridgeContentConnection
          .where(enabled: true)
          .order(:platform, :name, :id)
          .select { |connection| connection.allows_direction?("from_discourse") }
    end

    def from_discourse_records
      DiscussionBridgeBridgeRecord.where(direction: "from_discourse")
    end

    def verified_publications
      DiscussionBridgeCmsMapping.joins(content_binding: :bridge_record)
        .where(mapping_state: "active")
        .where("desired_source_revision IS NOT NULL AND desired_source_revision = publicly_verified_source_revision")
        .where(<<~SQL)
          EXISTS (
            SELECT 1 FROM discussion_bridge_cms_work latest
            WHERE latest.cms_mapping_id = discussion_bridge_cms_mappings.id
              AND latest.state = 'verified' AND latest.action = 'publish_revision'
              AND latest.source_revision = discussion_bridge_cms_mappings.desired_source_revision
              AND latest.id = (
                SELECT current_work.id FROM discussion_bridge_cms_work current_work
                WHERE current_work.cms_mapping_id = discussion_bridge_cms_mappings.id
                ORDER BY current_work.created_at DESC, current_work.id DESC LIMIT 1
              )
          )
        SQL
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
        allowed_lanes: connection.allowed_lanes,
        author_username: connection.effective_author&.username,
      }
    end

    def current_presentation_mode(binding)
      return unless binding

      CmsConfiguration.current!(binding.content_connection.reload).fetch("policy").fetch("presentation_mode")
    rescue CmsProtocol::Error
      # Retained delivery/scope diagnostics remain readable when the current
      # selection is unavailable. The creation-time mode is not a fallback.
      nil
    end

    def publication_payload(record)
      binding = record.active_binding("presentation")
      mapping = binding && DiscussionBridgeCmsMapping.find_by(content_binding_id: binding.id)
      delivery = mapping && CmsDeliveryProjection.call(mapping)
      {
        resource_id: record.resource_id,
        state: record.state,
        discussion_status: record.state,
        publication_status: delivery ? delivery.fetch("publication_status") : "untracked",
        delivery: delivery,
        topic_id: record.topic_id,
        title: record.topic&.title || record.title,
        topic_url: record.topic&.url,
        connection_id: binding&.content_connection_id,
        connection_name: binding&.content_connection&.name,
        platform: binding&.content_connection&.platform,
        external_id: binding&.external_id,
        canonical_url: binding&.canonical_url,
        lane: record.lane,
        # Current desired selection, matching Mapping/preview. Neither this nor
        # the explicitly historical initial value establishes an applied mode.
        presentation_mode: current_presentation_mode(binding),
        initial_presentation_mode: binding&.presentation_mode,
        presentation_move_intent: mapping&.presentation_move_intent&.slice(
          "intent_id", "requested_url", "requested_at", "state", "work_id", "attention_code",
        ),
      }
    end

    def recent_records
      from_discourse_records
        .includes(:topic, content_bindings: :content_connection)
        .order(updated_at: :desc, id: :desc)
        .limit(20)
        .map { |record| publication_payload(record) }
    end

    def ensure_administrator
      raise Discourse::InvalidAccess unless current_user&.admin?
    end

    def ensure_staff
      raise Discourse::InvalidAccess unless current_user&.staff?
    end

    def ensure_publisher_enabled
      raise Discourse::NotFound unless SiteSetting.discussion_bridge_publisher_enabled
    end
  end
end
