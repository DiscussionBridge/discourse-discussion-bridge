# frozen_string_literal: true

module DiscussionBridge
  class AdapterBridgeRecordsController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_json_request
    before_action :ensure_enabled
    before_action :authenticate_connection

    PER_PAGE = 100
    MAX_PAGE = 10_000

    def create
      data = BridgeRecordRequest.call(params.require(:bridge_record))
      unless @content_connection.allows_direction?(data[:direction]) &&
          @content_connection.allows_lane?(data[:lane]) &&
          @content_connection.allows_origin?(data[:canonical_url])
        render json: rejection("connection_scope_denied"), status: :forbidden
        return
      end

      DiscussionBridgeContentConnection.transaction do
        @content_connection.lock!
        SourceAuthorship.observe!(
          connection: @content_connection,
          source_authors: data[:source_authors],
        )
      end
      actor = User.find_by(username_lower: SiteSetting.discussion_bridge_service_username.downcase)
      authorship = SourceAuthorship.resolve(connection: @content_connection, request: data)
      unless authorship.allowed?
        render json: rejection(authorship.reason), status: :unprocessable_entity
        return
      end
      author = authorship.author
      lane_resolution = LanePolicies.resolve(value: SiteSetting.discussion_bridge_lane_policies, lane: data[:lane])
      authority = ForumAuthority.call(
        actor: actor,
        category_id: lane_resolution.category_id || SiteSetting.discussion_bridge_effective_category_id,
        tags: lane_resolution.tags || SiteSetting.discussion_bridge_effective_tags,
      ) if actor
      policy = PolicyEvaluator.call(
        request: policy_request(data),
        settings: PolicyEvaluator::Settings.new(
          enabled: SiteSetting.discussion_bridge_enabled,
          endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
          connection_id: @content_connection.public_id,
          trusted_origins: @content_connection.allowed_origins,
          service_username: SiteSetting.discussion_bridge_service_username,
        ),
        actor: actor,
        author: author,
        authority: authority,
        lane_resolution: lane_resolution,
      )
      result = BridgeRecordResolver.call(connection: @content_connection, request: data, policy: policy)
      render json: result.to_h.merge(core_fallback: false), status: status_for(result.outcome)
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, ArgumentError
      render json: rejection("invalid_request"), status: :unprocessable_entity
    end

    def index
      page = Integer(params[:page].presence || 1, exception: false)
      raise Discourse::InvalidParameters.new(:page) unless page&.between?(1, MAX_PAGE)

      records = DiscussionBridgeBridgeRecord
        .joins(:content_bindings)
        .where(discussion_bridge_content_bindings: { content_connection_id: @content_connection.id, state: "active" })
        .includes(topic: :first_post)
        .order(updated_at: :desc, id: :desc)
      total = records.distinct.count
      records = records.distinct.offset((page - 1) * PER_PAGE).limit(PER_PAGE)
      render json: {
        bridge_records: records.map { |record| adapter_record(record) },
        pagination: {
          page: page,
          per_page: PER_PAGE,
          total: total,
          pages: [(total.to_f / PER_PAGE).ceil, 1].max,
        },
      }
    end

    def show
      record = DiscussionBridgeBridgeRecord
        .joins(:content_bindings)
        .where(
          discussion_bridge_content_bindings: {
            content_connection_id: @content_connection.id,
            state: "active",
          },
        )
        .find_by!(resource_id: params[:resource_id])
      render json: { bridge_record: adapter_record(record) }
    end

    private

    def ensure_json_request
      raise Discourse::InvalidParameters.new(:format) unless request.format.json?
    end

    def ensure_enabled
      return if SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled

      render json: rejection("endpoint_disabled"), status: :service_unavailable
    end

    def authenticate_connection
      @content_connection = ContentConnectionAuthenticator.call(request)
      render json: rejection("unauthorized"), status: :unauthorized unless @content_connection
    end

    def policy_request(data)
      {
        connection_id: @content_connection.public_id,
        source_url: data.fetch(:canonical_url),
        visibility: data.fetch(:visibility, "unlisted"),
        lane: data[:lane],
      }
    end

    def adapter_record(record)
      topic = record.topic
      first_post = topic&.first_post
      {
        resource_id: record.resource_id,
        direction: record.direction,
        state: record.state,
        title: record.title,
        topic_id: record.topic_id,
        topic_url: topic&.url,
        source_authors: record.source_authors,
        primary_source_author_id: record.primary_source_author_id,
        content_html: record.direction == "from_discourse" ? first_post&.cooked : nil,
        source: record.direction == "from_discourse" ? discourse_source(topic, first_post) : nil,
        bindings: record.content_bindings.where(content_connection_id: @content_connection.id).map do |binding|
          {
            role: binding.role,
            state: binding.state,
            external_id: binding.external_id,
            canonical_url: binding.canonical_url,
          }
        end,
      }
    end

    def discourse_source(topic, first_post)
      return nil unless topic && first_post

      author = first_post.user
      {
        platform: "discourse",
        origin: Discourse.base_url,
        topic_id: topic.id,
        topic_url: topic.url,
        post_id: first_post.id,
        post_number: first_post.post_number,
        post_version: first_post.version,
        revision: "post:#{first_post.id}:version:#{first_post.version}",
        updated_at: first_post.updated_at&.iso8601(6),
        author: {
          username: author&.username,
          name: author&.name.presence || author&.username,
          profile_url: author ? "#{Discourse.base_url}/u/#{author.username_lower}" : nil,
        },
      }
    end

    def rejection(reason)
      { outcome: "rejected", reason: reason, core_fallback: false }
    end

    def status_for(outcome)
      return :created if outcome == "created"
      return :ok if outcome == "resolved"
      return :conflict if outcome == "reconciliation_required"

      :unprocessable_entity
    end
  end
end
