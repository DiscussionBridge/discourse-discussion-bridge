# frozen_string_literal: true

module ::DiscussionBridge
  class PublisherController < ::ApplicationController
    PUBLICATION_WORK_PAGE_SIZE = 50
    MAX_PUBLICATION_WORK_PAGE = 10_000
    PUBLICATION_WORK_FILTERS = %w[all attention].freeze
    VISIBILITY_BATCH_SIZE = 500

    requires_plugin DiscussionBridge::PLUGIN_NAME
    before_action :ensure_staff
    before_action :ensure_publisher_enabled

    def overview
      connections = available_connections
      blockers = readiness_blockers(connections)
      summary = publication_visibility_summary
      work_page = publication_work_page
      render json: {
        product: {
          name: "DiscussionBridge",
          version: DiscussionBridge::VERSION,
          ready: blockers.empty?,
          blockers: blockers,
        },
        connections: connections.map { |connection| connection_payload(connection) },
        metrics: {
          published_topics: summary.fetch(:published_topics),
          presentations: summary.fetch(:presentations),
          connected_platforms: connections.map(&:platform).uniq.count,
          publication_work: PublicationWorkProtocol::STATES.index_with do |state|
            summary.fetch(:work_counts).fetch(state, 0)
          end,
        },
        recent_records: recent_records,
        publication_work: work_page.fetch(:items),
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
      connection = publication_connection!
      PublicationControl.set!(
        user: current_user,
        connection: connection,
        topic: topic,
        decision: params.require(:publication_policy).fetch(:decision),
      )
      render json: topic_status_payload(topic)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound,
           AdapterRequestBoundary::Error, ArgumentError => error
      render_local_error(error)
    end

    def reconcile_topic
      topic = visible_topic
      connection = publication_connection!
      record = PublicationControl.mapped_record(connection: connection, topic: topic)
      raise ActiveRecord::RecordNotFound unless record

      SourceRevocationRegistry.reconcile_record!(record: record, connection: connection)
      render json: topic_status_payload(topic)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound,
           AdapterRequestBoundary::Error, ArgumentError => error
      render_local_error(error)
    end

    def correct_presentation
      visible_publication_record!(params.require(:resource_id))
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
      visible_publication_record!(params.require(:resource_id))
      result = VerifiedUrlMigrator.call(
        user: current_user,
        resource_id: params.require(:resource_id),
        role: "presentation",
        old_url: input.fetch(:old_url),
        new_url: input.fetch(:new_url),
        external_id: input.fetch(:external_id),
        native_identity_confirmed: boolean(input.fetch(:native_identity_confirmed)),
        cross_origin_approved: boolean(input[:cross_origin_approved]),
      )
      render json: publication_payload(result.record).merge(
        outcome: result.outcome,
        redirect_status: result.redirect_status,
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound,
           AdapterRequestBoundary::Error, ArgumentError => error
      render_local_error(error)
    end

    def retry_publication_work
      work = DiscussionBridgePublicationWork.includes(bridge_record: :topic).find(params.require(:id))
      ensure_visible_publication_record!(work.bridge_record)
      PublicationWorkRegistry.manual_retry!(
        work: work,
        authorized_by: current_user,
        condition_corrected: boolean(params.require(:retry).fetch(:condition_corrected)),
      )
      render json: {
        outcome: "available",
        publication_work: publication_work_payload(work.reload),
      }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound,
           AdapterRequestBoundary::Error, ArgumentError => error
      render_local_error(error)
    end

    private

    def available_connections
      @available_connections ||= DiscussionBridgeContentConnection
        .where(enabled: true)
        .order(:platform, :name, :id)
        .select do |connection|
          connection.allows_direction?("from_discourse") &&
            ConnectionCapability.publication_active?(connection)
        end
    end

    def from_discourse_record_scope
      DiscussionBridgeBridgeRecord.where(direction: "from_discourse")
    end

    def visible_publication_record!(resource_id)
      record = from_discourse_record_scope.includes(:topic).find_by!(resource_id: resource_id)
      ensure_visible_publication_record!(record)
      record
    end

    def ensure_visible_publication_record!(record)
      raise ActiveRecord::RecordNotFound unless record.topic && guardian.can_see?(record.topic)
    end

    def readiness_blockers(connections)
      blockers = []
      blockers << "plugin_disabled" unless SiteSetting.discussion_bridge_enabled
      blockers << "endpoint_disabled" unless SiteSetting.discussion_bridge_endpoint_enabled
      blockers << "from_discourse_connection" if connections.empty?
      blockers << "publication_work_attention" if publication_visibility_summary.fetch(:attention)
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
        catalog_required: connection.catalog_required,
        catalog_refresh_requested_at: connection.platform_catalog_refresh_requested_at,
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
        lane: record.lane,
        native_materialization: binding&.native_materialization || false,
        source_revision: record.source_revision,
        source_revision_sequence: record.source_revision_sequence,
        source_updated_at: record.source_updated_at,
        presentation_mode: binding&.presentation_mode || record.presentation_mode,
        delivery: latest_work_payload(record, binding) || {
          state: "pending",
          action: nil,
          failure_code: nil,
        },
      }
    end

    def recent_records
      publication_visibility_summary.fetch(:recent_records).map { |record| publication_payload(record) }
    end

    def visible_topic
      topic = Topic.includes(:category, :tags, :first_post).find(params.require(:topic_id))
      guardian.ensure_can_see!(topic)
      topic
    end

    def publication_connection!
      connection = available_connections.find do |candidate|
        candidate.id == params.require(:connection_id).to_i
      end
      raise ActiveRecord::RecordNotFound unless connection

      connection
    end

    def topic_status_payload(topic)
      records = from_discourse_record_scope.where(topic_id: topic.id).includes(
        :publication_works,
        content_bindings: :content_connection,
      ).order(:id)
      publications = records.filter_map do |record|
        binding = record.content_bindings.find do |candidate|
          candidate.role == "presentation" && candidate.state == "active" &&
            candidate.content_connection.enabled &&
            candidate.content_connection.allows_direction?("from_discourse")
        end
        next unless binding

        override = DiscussionBridgePublicationOverride.includes(:set_by).find_by(
          content_connection_id: binding.content_connection_id,
          topic_id: topic.id,
        )
        {
          connection: connection_payload(binding.content_connection),
          override: override ? {
            decision: override.decision,
            set_by: override.set_by.username,
            updated_at: override.updated_at,
          } : { decision: "inherit" },
          effective: {
            included: override&.decision != "exclude",
            reason: override&.decision == "exclude" ? "operator_hold" : nil,
          },
          publication: publication_payload(record),
        }
      end
      {
        topic_id: topic.id,
        title: topic.title,
        topic_url: topic.url,
        discussion: {
          visible: topic.visible,
          closed: topic.closed,
          archived: topic.archived,
          reply_count: [topic.posts_count.to_i - 1, 0].max,
        },
        publication_summary: PublicationSummary.call(topic),
        publications: publications,
      }
    end

    def latest_work_payload(record, binding)
      work = binding && record.publication_works
        .select { |item| item.content_connection_id == binding.content_connection_id }
        .max_by(&:id)
      work && publication_work_payload(work)
    end

    def publication_work_page
      filter = params[:publication_filter].presence || "all"
      raise Discourse::InvalidParameters.new(:publication_filter) if
        PUBLICATION_WORK_FILTERS.exclude?(filter)
      page = Integer(params[:publication_page].presence || 1, exception: false)
      raise Discourse::InvalidParameters.new(:publication_page) unless
        page&.between?(1, MAX_PUBLICATION_WORK_PAGE)

      scope = DiscussionBridgePublicationWork.joins(bridge_record: :topic)
        .merge(from_discourse_record_scope)
        .where(topics: { deleted_at: nil })
        .includes(:content_connection, bridge_record: :topic)
      scope = scope.where(state: "operator_attention") if filter == "attention"
      offset = (page - 1) * PUBLICATION_WORK_PAGE_SIZE
      total = 0
      items = []
      each_work_batch(scope) do |batch|
        visible = guardian.can_see_topic_ids(
          topic_ids: batch.map { |work| work.bridge_record.topic_id }.uniq,
        ).to_set
        batch.each do |work|
          next if visible.exclude?(work.bridge_record.topic_id)

          items << publication_work_payload(work) if
            total >= offset && items.length < PUBLICATION_WORK_PAGE_SIZE
          total += 1
        end
      end
      {
        items: items,
        page: page,
        per_page: PUBLICATION_WORK_PAGE_SIZE,
        total: total,
        pages: [(total.to_f / PUBLICATION_WORK_PAGE_SIZE).ceil, 1].max,
        filter: filter,
      }
    end

    def publication_visibility_summary
      @publication_visibility_summary ||= begin
        summary = {
          published_topics: 0,
          presentations: 0,
          work_counts: Hash.new(0),
          attention: false,
          recent_records: [],
        }
        each_visible_record_scope do |scope, visible_topic_count|
          summary[:published_topics] += visible_topic_count
          summary[:presentations] += scope.count
          DiscussionBridgePublicationWork.where(bridge_record_id: scope.select(:id))
            .group(:state).count.each do |state, count|
              summary[:work_counts][state] += count
            end
          summary[:attention] ||= DiscussionBridgePublicationWork
            .where(bridge_record_id: scope.select(:id), state: "operator_attention").exists?
          candidates = scope.includes(
            :publication_works,
            :topic,
            content_bindings: :content_connection,
          ).order(updated_at: :desc, id: :desc).limit(20).to_a
          summary[:recent_records] = (summary[:recent_records] + candidates)
            .sort_by { |record| [record.updated_at, record.id] }.reverse.first(20)
        end
        summary
      end
    end

    def each_visible_record_scope
      after_topic_id = 0
      loop do
        topic_ids = from_discourse_record_scope.joins(:topic)
          .where(topics: { deleted_at: nil })
          .where("topic_id > ?", after_topic_id).distinct.order(:topic_id)
          .limit(VISIBILITY_BATCH_SIZE).pluck(:topic_id)
        break if topic_ids.empty?

        visible_ids = guardian.can_see_topic_ids(topic_ids: topic_ids)
        yield from_discourse_record_scope.where(topic_id: visible_ids), visible_ids.length if
          visible_ids.any?
        after_topic_id = topic_ids.last
      end
    end

    def each_work_batch(scope)
      cursor_time = nil
      cursor_id = nil
      loop do
        page = scope
        if cursor_time
          page = page.where(
            "discussion_bridge_publication_works.updated_at < :time OR " \
              "(discussion_bridge_publication_works.updated_at = :time AND " \
              "discussion_bridge_publication_works.id < :id)",
            time: cursor_time,
            id: cursor_id,
          )
        end
        batch = page.order(updated_at: :desc, id: :desc).limit(VISIBILITY_BATCH_SIZE).to_a
        break if batch.empty?

        yield batch
        cursor_time = batch.last.updated_at
        cursor_id = batch.last.id
      end
    end

    def publication_work_payload(work)
      {
        id: work.id,
        work_id: work.work_id,
        resource_id: work.bridge_record.resource_id,
        topic_id: work.bridge_record.topic_id,
        topic_url: work.bridge_record.topic&.url,
        title: work.bridge_record.title,
        connection_id: work.content_connection_id,
        connection_name: work.content_connection.name,
        platform: work.content_connection.platform,
        action: work.action,
        state: work.state,
        attempt_count: work.attempt_count,
        retry_generation: work.retry_generation,
        failure_code: work.failure_code,
        failure_detail: work.failure_detail,
        available_at: work.available_at,
        next_retry_at: work.next_retry_at,
        updated_at: work.updated_at,
      }
    end

    def native_materialization(value)
      return false if value.nil? || value == false || value == "false"
      return true if value == true || value == "true"

      raise ArgumentError, "invalid native_materialization"
    end

    def boolean(value)
      value == true || value == "true"
    end

    def render_local_error(error)
      errors = if error.is_a?(AdapterRequestBoundary::Error)
        [error.error_code]
      elsif error.respond_to?(:record)
        error.record.errors.full_messages
      else
        [error.message]
      end
      render json: { errors: errors }, status: :unprocessable_entity
    end

    def ensure_staff
      raise Discourse::InvalidAccess unless current_user&.staff?
    end

    def ensure_publisher_enabled
      raise Discourse::NotFound unless SiteSetting.discussion_bridge_publisher_enabled
    end
  end
end
