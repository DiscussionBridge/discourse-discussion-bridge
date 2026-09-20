# frozen_string_literal: true

module DiscussionBridge
  class AdapterSourceTopicsController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_json_request
    before_action :ensure_enabled
    before_action :authenticate_connection
    before_action :ensure_publication_scope

    PER_PAGE = 20
    MAX_SOURCE_BYTES = DiscussionBridge::BridgeRecordRequest::MAX_CONTENT_HTML_BYTES

    def index
      relation = PublicationTopicScope.relation(@content_connection)
      run = source_run(relation, feed: "topics")
      topics = relation.includes(:category, :tags, first_post: :user)
        .where("topics.id > ? AND topics.id <= ?", run.after_id, run.high_water_id)
        .order(id: :asc).limit(PER_PAGE).to_a

      records = DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(direction: "from_discourse", topic_id: topics.map(&:id))
        .where(discussion_bridge_content_bindings: {
          content_connection_id: @content_connection.id, role: "presentation", state: "active",
        }).includes(:content_bindings).index_by(&:topic_id)

      render json: {
        source_topics: topics.map { |topic| topic_payload(topic, records[topic.id]) },
        connection_policy: {
          catalog_revision: @content_connection.platform_catalog_revision,
          mapping_revision: @content_connection.destination_mapping_revision,
          policy_revision: TopicPublicationState.policy_revision(@content_connection),
          catalog_observed_at: @content_connection.platform_catalog_observed_at&.iso8601(6),
        },
        pagination: {
          per_page: PER_PAGE,
          eligible_at_start: run.total,
          high_water_topic_id: run.high_water_id,
          complete: topics.length < PER_PAGE,
          next_cursor: next_cursor(run, topics.last&.id, topics.length),
        },
      }
    rescue ArgumentError => error
      render json: {
        outcome: "rejected", reason: source_feed_reason(error), errors: [error.message],
      }, status: :unprocessable_entity
    end

    def show
      topic = Topic.includes(:category, :tags, first_post: :user).find_by(id: params[:topic_id])
      unless topic
        render json: { eligible: false, reason: "topic_missing" }
        return
      end
      eligibility = PublicationTopicScope.eligibility(@content_connection, topic)
      unless eligibility.fetch(:eligible)
        render json: { eligible: false, reason: eligibility.fetch(:reason) }
        return
      end
      bytes = topic.first_post.cooked.to_s.bytesize
      maximum = maximum_source_bytes
      if bytes > maximum
        render json: {
          outcome: "attention",
          reason: "source_content_too_large",
          topic_id: topic.id,
          content_bytes: bytes,
          maximum_bytes: maximum,
        }, status: :unprocessable_entity
        return
      end
      render json: { eligible: true, source_topic: topic_payload(topic, existing_record(topic.id)).merge(
        content_html: topic.first_post.cooked,
      ) }
    end

    def revocations
      relation = revocation_records
      run = source_run(relation, feed: "revocations")
      records = relation.where("discussion_bridge_bridge_records.id > ? AND discussion_bridge_bridge_records.id <= ?",
                                run.after_id, run.high_water_id)
        .includes(topic: [:category, :tags, :first_post])
        .order(id: :asc).limit(PER_PAGE).to_a
      render json: {
        publication_revocations: records.map { |record| revocation_payload(record) },
        pagination: {
          per_page: PER_PAGE,
          eligible_at_start: run.total,
          high_water_record_id: run.high_water_id,
          complete: records.length < PER_PAGE,
          next_cursor: next_cursor(run, records.last&.id, records.length),
        },
      }
    rescue ArgumentError => error
      render json: {
        outcome: "rejected", reason: source_feed_reason(error), errors: [error.message],
      }, status: :unprocessable_entity
    end

    def revocation
      record = DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(direction: "from_discourse")
        .where(discussion_bridge_content_bindings: {
          content_connection_id: @content_connection.id, role: "presentation", state: "active",
        }).includes(topic: [:category, :tags, :first_post])
        .find_by!(resource_id: params[:resource_id])
      current = revocation_records.where(id: record.id).exists?
      render json: {
        revoked: current,
        publication_revocation: current ? revocation_payload(record) : nil,
      }
    rescue ActiveRecord::RecordNotFound
      render json: { errors: ["publication not found"] }, status: :not_found
    end

    def resolve
      input = params.require(:publication)
      result = nil
      state = nil
      DiscussionBridgeBridgeRecord.transaction do
        @content_connection.lock!
        existing_record(params.require(:topic_id))&.lock!
        topic = Topic.includes(:category, :tags, :first_post).lock.find(params.require(:topic_id))
        topic.first_post&.lock!
        topic.reload
        topic.association(:tags).reload
        raise ArgumentError, "topic is not eligible" unless
          PublicationTopicScope.eligibility(@content_connection, topic)[:eligible]
        state = TopicPublicationState.for_topic(connection: @content_connection, topic: topic)
        raise ArgumentError, state.destination.fetch("reasons").join(",") unless
          state.destination.fetch("state") == "ready"
        raise ArgumentError, "source revision changed" unless
          input.fetch(:source_revision) == state.source_revision
        raise ArgumentError, "publication plan changed" unless
          input.fetch(:publication_revision) == state.publication_revision
        raise ArgumentError, "destination mapping changed" unless
          input.fetch(:mapping_revision) == @content_connection.destination_mapping_revision
        raise ArgumentError, "destination plan changed" unless
          TopicPublicationState.destination_matches?(input.fetch(:destination), state.destination)
        result = FromDiscourseRecordCreator.call_for_connection(
          connection: @content_connection,
          topic_id: topic.id,
          expected_source_revision: state.source_revision,
          external_id: input.fetch(:external_id),
          canonical_url: input.fetch(:canonical_url),
          lane: input[:lane],
          native_materialization: boolean(input[:native_materialization]),
        )
        result.record.update!(
          destination_state: result.record.acknowledged_publication_revision == state.publication_revision ?
            result.record.destination_state : "pending",
          pending_publication_revision: state.publication_revision,
          pending_mapping_revision: @content_connection.destination_mapping_revision,
          pending_destination: state.destination,
        )
      end
      render json: record_payload(result.record).merge(outcome: result.outcome),
             status: result.outcome == "created" ? :created : :ok
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid,
           ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound, ArgumentError => error
      render json: {
        outcome: "rejected", reason: reason_for(error), errors: errors_for(error),
      }, status: :unprocessable_entity
    end

    private

    def topic_payload(topic, record)
      post = topic.first_post
      state = TopicPublicationState.for_topic(connection: @content_connection, topic: topic)
      source = TopicPublicationState.adapter_source(topic)
      {
        topic_id: topic.id,
        topic_url: source.fetch("topic_url"),
        title: source.fetch("title"),
        source_revision: PublicationTopicScope.revision(topic),
        content_bytes: post.cooked.to_s.bytesize,
        source_updated_at: post.updated_at&.iso8601(6),
        category: topic.category && {
          id: topic.category.id, slug: topic.category.slug, name: topic.category.name,
        },
        tags: topic.tags.sort_by(&:name).map { |tag| { id: tag.id, slug: tag.name, name: tag.name } },
        author: source.fetch("author"),
        publication: record && record_payload(record),
        publication_revision: state.publication_revision,
        destination: state.destination,
      }
    end

    def revocation_payload(record)
      state = TopicPublicationState.for_revocation(connection: @content_connection, record: record)
      binding = record.active_binding("presentation")
      {
        resource_id: record.resource_id,
        topic_id: record.topic_id,
        reason: state.eligibility.fetch(:reason),
        publication_revision: state.publication_revision,
        policy_revision: state.policy_revision,
        destination_state: record.destination_state,
        acknowledged_publication_revision: record.acknowledged_publication_revision,
        last_delivery_outcome: record.last_delivery_outcome,
        publication_program: record.publication_program,
        external_id: binding&.external_id,
        canonical_url: binding&.canonical_url,
      }
    end

    def existing_record(topic_id)
      DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(direction: "from_discourse", topic_id: topic_id)
        .where(discussion_bridge_content_bindings: {
          content_connection_id: @content_connection.id, role: "presentation", state: "active",
        }).includes(:content_bindings).first
    end

    def record_payload(record)
      binding = record.active_binding("presentation")
      {
        resource_id: record.resource_id,
        state: record.state,
        destination_state: record.destination_state,
        acknowledged_source_revision: record.acknowledged_source_revision,
        acknowledged_publication_revision: record.acknowledged_publication_revision,
        acknowledged_mapping_revision: record.acknowledged_mapping_revision,
        acknowledged_destination: record.acknowledged_destination,
        pending_publication_revision: record.pending_publication_revision,
        pending_mapping_revision: record.pending_mapping_revision,
        pending_destination: record.pending_destination,
        publication_program: record.publication_program,
        last_delivery_outcome: record.last_delivery_outcome,
        external_id: binding&.external_id,
        canonical_url: binding&.canonical_url,
      }
    end

    def source_run(relation, feed:)
      if params[:cursor].present?
        SourceTopicFeedSnapshot.load(params[:cursor], connection: @content_connection, feed: feed)
      else
        SourceTopicFeedSnapshot.start(connection: @content_connection, relation: relation, feed: feed)
      end
    end

    def next_cursor(run, last_id, count)
      return nil if count < PER_PAGE || last_id.nil?
      SourceTopicFeedSnapshot.issue(
        connection: @content_connection,
        run: SourceTopicFeedSnapshot.advance(run, after_id: last_id),
      )
    end

    def revocation_records
      base = DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(direction: "from_discourse", publication_program: %w[forum_sync_pending forum_sync])
        .where(discussion_bridge_content_bindings: {
          content_connection_id: @content_connection.id, role: "presentation", state: "active",
        }).distinct
      eligible_ids = PublicationTopicScope.relation(@content_connection).select(:id)
      base.where(topic_id: nil).or(base.where.not(topic_id: eligible_ids))
    end

    def maximum_source_bytes
      platform_limit = @content_connection.platform_catalog.dig("limits", "content_bytes").to_i
      platform_limit = MAX_SOURCE_BYTES unless platform_limit.positive?
      [MAX_SOURCE_BYTES, platform_limit].min
    end

    def source_feed_reason(error)
      case error.message
      when "source feed cursor is stale" then "source_feed_cursor_stale"
      when "invalid source feed cursor" then "invalid_source_feed_cursor"
      else "invalid_source_feed_request"
      end
    end

    def ensure_json_request
      raise Discourse::InvalidParameters.new(:format) unless request.format.json?
    end

    def ensure_enabled
      return if SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled
      render json: { outcome: "rejected", reason: "endpoint_disabled" }, status: :service_unavailable
    end

    def authenticate_connection
      @content_connection = ContentConnectionAuthenticator.call(request, identity: :catalog)
      render json: { outcome: "rejected", reason: "unauthorized" }, status: :unauthorized unless @content_connection
    end

    def ensure_publication_scope
      return if performed?
      return if @content_connection.enabled && @content_connection.forum_publication_enabled &&
        @content_connection.allows_direction?("from_discourse")
      render json: { outcome: "rejected", reason: "publication_scope_disabled" }, status: :forbidden
    end

    def boolean(value)
      return false if value.nil? || value == false || value == "false"
      return true if value == true || value == "true"
      raise ArgumentError, "invalid native_materialization"
    end

    def errors_for(error)
      error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
    end

    def reason_for(error)
      {
        "topic is not eligible" => "topic_ineligible",
        "source revision changed" => "source_revision_changed",
        "publication plan changed" => "publication_revision_changed",
        "destination mapping changed" => "destination_mapping_changed",
        "destination plan changed" => "destination_plan_changed",
        "binding identity conflict" => "binding_identity_conflict",
        "publication identity changed; migration required" => "publication_identity_changed",
        "publication program conflict" => "publication_program_conflict",
      }.fetch(error.message, "invalid_source_topic_request")
    end
  end
end
