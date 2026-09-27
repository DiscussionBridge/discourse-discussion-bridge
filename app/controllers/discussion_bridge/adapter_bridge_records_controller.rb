# frozen_string_literal: true

module DiscussionBridge
  class AdapterBridgeRecordsController < AdapterController

    PER_PAGE = 100
    MAX_PAGE = 10_000

    def create
      data = BridgeRecordRequest.call(params.require(:bridge_record))
      unless @content_connection.allows_direction?(data[:direction]) &&
          @content_connection.allows_lane?(data[:lane]) &&
          @content_connection.allows_origin?(data[:canonical_url])
        render_protocol_error("scope_denied")
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
        render_protocol_error("policy_denied")
        return
      end
      author = authorship.author
      lane_resolution = LanePolicies.resolve(value: SiteSetting.discussion_bridge_lane_policies, lane: data[:lane])
      authority = ForumAuthority.call(
        actor: actor,
        category_id: lane_resolution.category_id || @content_connection.default_category_id ||
          SiteSetting.discussion_bridge_effective_category_id,
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
      if result.outcome == "rejected"
        render_protocol_error("policy_denied")
      else
        render_protocol_json(result.to_h.merge(core_fallback: false), status: status_for(result.outcome))
      end
    end

    def index
      page = Integer(params[:page].presence || 1, exception: false)
      raise AdapterRequestBoundary::Error, "malformed_value" unless page&.between?(1, MAX_PAGE)

      records = scoped_records
      snapshot = AdapterFeedSnapshot.capture(records)
      token = params[:snapshot].presence
      if page > 1 && token.blank?
        raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch"
      end
      if token && !AdapterFeedSnapshot.valid?(token, connection: @content_connection, snapshot: snapshot)
        raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch"
      end
      token ||= AdapterFeedSnapshot.issue(connection: @content_connection, snapshot: snapshot)
      page_records = records.distinct.offset((page - 1) * PER_PAGE).limit(PER_PAGE).to_a
      unless AdapterFeedSnapshot.capture(scoped_records) == snapshot
        raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch"
      end
      payload = {
        bridge_records: page_records.map { |record| adapter_record(record) },
        pagination: {
          page: page,
          per_page: PER_PAGE,
          total: snapshot.total,
          pages: [(snapshot.total.to_f / PER_PAGE).ceil, 1].max,
          snapshot: token,
        },
      }
      render_protocol_json(payload)
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
      unless record_within_connection_scope?(record)
        render_protocol_error("scope_denied")
        return
      end
      render_protocol_json({ bridge_record: adapter_record(record) })
    end

    private

    def scoped_records
      records = DiscussionBridgeBridgeRecord
        .joins(:content_bindings)
        .where(discussion_bridge_content_bindings: { content_connection_id: @content_connection.id, state: "active" })
        .where(direction: @content_connection.allowed_directions)
        .includes(topic: :first_post)
        .order(id: :asc)
      records = if Array(@content_connection.allowed_lanes).empty?
        records.where(lane: [nil, ""])
      else
        records.where(lane: @content_connection.allowed_lanes)
      end
      origin_patterns = Array(@content_connection.allowed_origins).map do |origin|
        "#{ActiveRecord::Base.sanitize_sql_like(origin)}/%"
      end
      origin_clause = Array.new(origin_patterns.length, "discussion_bridge_content_bindings.canonical_url LIKE ?").join(" OR ")
      records.where(origin_clause, *origin_patterns)
    end

    def maximum_json_bytes
      action_name == "create" ? BridgeRecordRequest::MAX_JSON_BYTES : nil
    end

    def allowed_query_fields
      action_name == "index" ? %w[page snapshot] : []
    end

    def allowed_body_fields
      action_name == "create" ? ["bridge_record"] : []
    end

    def require_known_nested_body_fields
      return unless action_name == "create"

      bridge_record = request.request_parameters["bridge_record"]
      return unless bridge_record.respond_to?(:keys)

      unknown = bridge_record.keys.map(&:to_s) - BridgeRecordRequest::ALLOWED_KEYS
      raise AdapterRequestBoundary::Error, "unknown_field" if unknown.any?

      Array(bridge_record["source_authors"]).each do |author|
        next unless author.respond_to?(:keys)

        unknown_author_fields = author.keys.map(&:to_s) - %w[id name profile_url]
        raise AdapterRequestBoundary::Error, "unknown_field" if unknown_author_fields.any?
      end
    end

    def body_correlation_id
      request.request_parameters.dig("bridge_record", "correlation_id")
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
            native_materialization: binding.native_materialization,
          }
        end,
      }
    end

    def record_within_connection_scope?(record)
      binding = record.content_bindings.find do |candidate|
        candidate.content_connection_id == @content_connection.id && candidate.state == "active"
      end
      binding && @content_connection.allows_direction?(record.direction) &&
        @content_connection.allows_lane?(record.lane) &&
        @content_connection.allows_origin?(binding.canonical_url)
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

    def status_for(outcome)
      return :created if outcome == "created"
      return :ok if outcome == "resolved"
      return :conflict if outcome == "reconciliation_required"

      :unprocessable_entity
    end
  end
end
