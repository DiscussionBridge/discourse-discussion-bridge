# frozen_string_literal: true

module ::DiscussionBridge
  class PublisherController < ::ApplicationController
    PUBLICATION_WORK_PAGE_SIZE = 50
    MAX_PUBLICATION_WORK_PAGE = 10_000
    PUBLICATION_WORK_FILTERS = %w[all attention].freeze

    requires_plugin DiscussionBridge::PLUGIN_NAME
    before_action :ensure_operator_view, only: %i[overview topic_status]
    before_action :ensure_operator_mutation, except: %i[overview topic_status]
    before_action :ensure_publisher_enabled

    def overview
      connections = available_connections
      work_counts = DiscussionBridgePublicationWorkItem.group(:state).count
      work_page = publication_work_page
      render json: {
        operator_access: {
          status: DiscussionBridge::OperatorServiceAccess.service.effective_status,
          can_view: DiscussionBridge::OperatorServiceAccess.view?(current_user),
          can_mutate: DiscussionBridge::OperatorServiceAccess.mutate?(current_user),
        },
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
        operator_events: operator_events,
        publication_work: work_page[:items],
        publication_work_pagination: work_page.except(:items),
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
      audit_operator_action(
        "topic_published",
        topic: result.record.topic,
        connection: result.record.active_binding("presentation")&.content_connection,
        bridge_record: result.record,
        details: { resource_id: result.record.resource_id },
      )
      render json: publication_payload(result.record).merge(outcome: result.outcome),
             status: result.outcome == "created" ? :created : :ok
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    def topic_status
      render json: topic_status_payload(visible_topic)
    end

    def update_topic_policy
      topic = visible_topic
      connection = publication_policy_connections.find do |candidate|
        candidate.id == params.require(:connection_id).to_i
      end
      raise ActiveRecord::RecordNotFound unless connection

      DiscussionBridge::PublicationOverrideManager.call(
        user: current_user,
        connection: connection,
        topic: topic,
        decision: params.require(:publication_policy).fetch(:decision),
      )
      audit_operator_action(
        "topic_policy_changed",
        topic: topic,
        connection: connection,
        details: { decision: params.require(:publication_policy).fetch(:decision) },
      )
      render json: topic_status_payload(topic)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    def reconcile_topic
      topic = visible_topic
      connection = publication_policy_connections.find do |candidate|
        candidate.id == params.require(:connection_id).to_i
      end
      raise ActiveRecord::RecordNotFound unless connection

      DiscussionBridge::PublicationWorkQueue.reconcile_topic!(
        topic_id: topic.id,
        connection: connection,
      )
      audit_operator_action("topic_reconciled", topic: topic, connection: connection)
      render json: topic_status_payload(topic)
    rescue ActiveRecord::RecordNotFound, ArgumentError => error
      render json: { errors: [error.message] }, status: :unprocessable_entity
    end

    def correct_presentation
      record = PresentationBindingCorrector.call(
        user: current_user,
        resource_id: params.require(:resource_id),
        canonical_url: params.require(:publication).fetch(:canonical_url),
      )
      audit_operator_action(
        "presentation_corrected",
        topic: record.topic,
        bridge_record: record,
        details: { resource_id: record.resource_id },
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
      audit_operator_action(
        "publication_url_migrated",
        topic: result.record.topic,
        bridge_record: result.record,
        details: { resource_id: result.record.resource_id },
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
      audit_operator_action(
        "publication_work_retried",
        topic: item.bridge_record&.topic,
        connection: item.content_connection,
        bridge_record: item.bridge_record,
        details: { action: item.action, resource_id: item.bridge_record&.resource_id },
      )
      render json: {
        outcome: "queued",
        publication_work: publication_work_payload(item.reload),
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

    def publication_policy_connections
      available_connections.select(&:forum_publication_enabled)
    end

    def visible_topic
      topic = Topic.includes(:category, :tags, first_post: :user).find(params.require(:topic_id))
      guardian.ensure_can_see!(topic)
      topic
    end

    def topic_status_payload(topic)
      connections = publication_policy_connections
      overrides = DiscussionBridgePublicationOverride.where(
        content_connection_id: connections.map(&:id),
        topic_id: topic.id,
      ).includes(:set_by).index_by(&:content_connection_id)
      records = from_discourse_records.where(topic_id: topic.id).includes(
        :publication_work_items,
        content_bindings: :content_connection,
      )

      {
        topic_id: topic.id,
        title: topic.title,
        topic_url: topic.url,
        connections: connections.map do |connection|
          topic_connection_payload(
            connection,
            topic,
            overrides[connection.id],
            records,
          )
        end,
      }
    end

    def topic_connection_payload(connection, topic, override, records)
      rule = DiscussionBridge::PublicationTopicScope.rule_eligibility(connection, topic)
      hard = DiscussionBridge::PublicationTopicScope.hard_eligibility(connection, topic)
      effective = DiscussionBridge::PublicationTopicScope.eligibility(connection, topic)
      binding_record = records.find do |record|
        record.content_bindings.any? do |binding|
          binding.role == "presentation" && binding.state == "active" &&
            binding.content_connection_id == connection.id
        end
      end
      work = connection.publication_work_items.find_by(topic_id: topic.id)
      basis = if !hard.fetch(:eligible)
        "safety_policy"
      elsif override
        "operator_override"
      else
        "connection_rules"
      end

      {
        connection: connection_payload(connection),
        rule: rule,
        override: override ? {
          decision: override.decision,
          set_by: override.set_by.username,
          updated_at: override.updated_at,
        } : { decision: "inherit" },
        effective: effective.merge(basis: basis, publish_allowed: hard.fetch(:eligible)),
        publication: binding_record && publication_payload(binding_record),
        work: work && publication_work_payload(work),
      }
    end

    def recent_records
      from_discourse_records.includes(:topic, :publication_work_items, content_bindings: :content_connection)
        .order(updated_at: :desc, id: :desc).limit(20).map { |record| publication_payload(record) }
    end

    def publication_work_page
      filter = params[:publication_filter].presence || "all"
      raise Discourse::InvalidParameters.new(:publication_filter) if
        PUBLICATION_WORK_FILTERS.exclude?(filter)

      scope = DiscussionBridgePublicationWorkItem.includes(:content_connection, bridge_record: :topic)
        .order(updated_at: :desc, id: :desc)
      if filter == "attention"
        scope = scope.where(state: DiscussionBridgePublicationWorkItem::ATTENTION_STATES)
      end
      total = scope.count
      pages = [(total.to_f / PUBLICATION_WORK_PAGE_SIZE).ceil, 1].max
      requested_page = begin
        Integer(params[:publication_page].presence || 1)
      rescue ArgumentError, TypeError
        1
      end
      page = [[requested_page, 1].max, MAX_PUBLICATION_WORK_PAGE, pages].min

      {
        items: scope.offset((page - 1) * PUBLICATION_WORK_PAGE_SIZE)
          .limit(PUBLICATION_WORK_PAGE_SIZE)
          .map { |item| publication_work_payload(item) },
        page: page,
        per_page: PUBLICATION_WORK_PAGE_SIZE,
        total: total,
        pages: pages,
        filter: filter,
      }
    end

    def publication_work_payload(item)
      record = item.bridge_record
      topic = record&.topic || Topic.with_deleted.includes(:first_post).find_by(id: item.topic_id)
      payload = {
        id: item.id,
        topic_id: item.topic_id,
        topic_url: topic&.url || "/t/#{item.topic_id}",
        title: record&.title || topic&.title,
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
      if item.reason == "source_content_too_large"
        platform_limit = item.content_connection.platform_catalog&.dig("limits", "content_bytes").to_i
        receiver_limit = DiscussionBridge::BridgeRecordRequest::MAX_PUBLICATION_CONTENT_HTML_BYTES
        effective_limit = platform_limit.positive? ? [platform_limit, receiver_limit].min : receiver_limit
        payload[:source_content_bytes] = topic&.first_post&.cooked.to_s.bytesize
        payload[:source_content_limit_bytes] = effective_limit
      end
      payload
    end

    def native_materialization(value)
      return false if value.nil? || value == false || value == "false"
      return true if value == true || value == "true"

      raise ArgumentError, "invalid native_materialization"
    end

    def ensure_operator_view
      raise Discourse::InvalidAccess unless DiscussionBridge::OperatorServiceAccess.view?(current_user)
    end

    def operator_events
      DiscussionBridgeOperatorEvent.includes(:actor_user, :topic, :content_connection)
        .order(created_at: :desc, id: :desc)
        .limit(50)
        .map do |event|
          {
            id: event.id,
            event_type: event.event_type,
            outcome: event.outcome,
            actor_username: event.actor_user&.username,
            topic_id: event.topic_id,
            topic_url: event.topic&.url,
            connection_name: event.content_connection&.name,
            details: event.details,
            created_at: event.created_at,
          }
        end
    end

    def ensure_operator_mutation
      raise Discourse::InvalidAccess unless DiscussionBridge::OperatorServiceAccess.mutate?(current_user)
    end

    def ensure_publisher_enabled
      raise Discourse::NotFound unless SiteSetting.discussion_bridge_publisher_enabled
    end

    def audit_operator_action(event_type, topic: nil, connection: nil, bridge_record: nil, details: {})
      return if current_user&.staff?

      DiscussionBridge::OperatorAudit.record(
        event_type: event_type,
        actor: current_user,
        topic: topic,
        connection: connection,
        bridge_record: bridge_record,
        details: details,
      )
    end
  end
end
