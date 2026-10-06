# frozen_string_literal: true

module DiscussionBridge
  class AdapterBridgeRecordsController < AdapterController
    PER_PAGE = 100
    MAX_PAGE = 10_000

    def create
      data = @bridge_request
      result = nil
      DiscussionBridgeContentConnection.transaction do
        @content_connection.lock!
        check_connection_scope!(data)
        SourceAuthorship.observe!(connection: @content_connection, source_authors: data[:source_authors])
        actor = User.find_by(username_lower: SiteSetting.discussion_bridge_service_username.downcase)
        authorship = SourceAuthorship.resolve(connection: @content_connection, request: data)
        unless authorship.allowed?
          # Retain the baseline discovery workflow: a held, authenticated source
          # author remains visible for the operator to map. This does not accept
          # a publication, update connection presence or mutate a native topic.
          @authorship_held = true
          next
        end
        lane = LanePolicies.resolve(value: SiteSetting.discussion_bridge_lane_policies, lane: data[:lane])
        authority = ForumAuthority.call(
          actor: actor,
          category_id: lane.category_id || @content_connection.default_category_id || SiteSetting.discussion_bridge_effective_category_id,
          tags: lane.tags || SiteSetting.discussion_bridge_effective_tags,
        ) if actor
        policy = PolicyEvaluator.call(
          request: { connection_id: @content_connection.public_id, source_url: data.fetch(:canonical_url),
                     visibility: data.fetch(:visibility, "unlisted"), lane: data[:lane] },
          settings: PolicyEvaluator::Settings.new(
            enabled: SiteSetting.discussion_bridge_enabled, endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
            connection_id: @content_connection.public_id, trusted_origins: @content_connection.allowed_origins,
            service_username: SiteSetting.discussion_bridge_service_username,
          ),
          actor: actor, author: authorship.author, authority: authority, lane_resolution: lane,
        )
        result = BridgeRecordResolver.call(connection: @content_connection, request: data, policy: policy)
        raise ActiveRecord::Rollback if result.outcome == "reconciliation_required"
      end
      if @authorship_held
        render_protocol_error(AdapterRequestBoundary::Error.new("policy_denied"))
        return
      end
      payload = result.to_h.merge(core_fallback: false, correlation_id: @correlation_id)
      if result.outcome == "reconciliation_required"
        payload.except!(:accepted_source_revision, :accepted_source_revision_sequence)
        payload[:resource_id] = payload[:topic_id] = payload[:topic_url] = nil
      else
        payload.except!(:conflict_fields)
      end
      status = { "created" => :created, "resolved" => :ok, "reconciliation_required" => :conflict }.fetch(result.outcome)
      render json: payload, status: status
    end

    def index
      value = request.query_parameters["page"] || "1"
      page = value.is_a?(String) && /\A[1-9]\d*\z/.match?(value) ? Integer(value) : nil
      raise AdapterRequestBoundary::Error.new("validation_failed") unless page&.between?(1, MAX_PAGE)
      payload = accepted_read do
        records = scoped_records
        total_pages = [(records.distinct.count.to_f / PER_PAGE).ceil, 1].max
        if page > total_pages || total_pages > MAX_PAGE
          raise AdapterRequestBoundary::Error.new("validation_failed")
        end
        {
          records: records.distinct.order(id: :asc).offset((page - 1) * PER_PAGE).limit(PER_PAGE).map do |record|
            AdapterProtocolRecords.call(record, connection: @content_connection)
          end,
          page: page, total_pages: total_pages, correlation_id: @correlation_id,
        }
      end
      render json: payload
    end

    def show
      payload = accepted_read do
        record = connection_records.find_by!(resource_id: params[:resource_id])
        unless scoped_records.where(id: record.id).exists?
          raise AdapterRequestBoundary::Error.new("scope_denied")
        end
        { bridge_record: AdapterProtocolRecords.call(record, connection: @content_connection),
          correlation_id: @correlation_id }
      end
      render json: payload
    end

    private

    def check_connection_scope!(data)
      raise AdapterRequestBoundary::Error.new("direction_denied") unless @content_connection.allows_direction?(data[:direction])
      unless @content_connection.enabled && @content_connection.allows_lane?(data[:lane]) &&
          @content_connection.allows_origin?(data[:canonical_url])
        raise AdapterRequestBoundary::Error.new("scope_denied")
      end
    end

    def connection_records
      DiscussionBridgeBridgeRecord.joins(:content_bindings).where(
        discussion_bridge_content_bindings: { content_connection_id: @content_connection.id, state: "active" },
      ).includes(topic: :first_post)
    end

    def scoped_records
      records = connection_records.where(direction: @content_connection.allowed_directions)
      records = if Array(@content_connection.allowed_lanes).empty?
        records.where(lane: [nil, ""])
      else
        records.where(lane: @content_connection.allowed_lanes)
      end
      origins = Array(@content_connection.allowed_origins).map { |origin| "#{ActiveRecord::Base.sanitize_sql_like(origin)}/%" }
      return records.none if origins.empty?
      clause = Array.new(origins.length, "discussion_bridge_content_bindings.canonical_url LIKE ?").join(" OR ")
      records.where(clause, *origins)
    end

    def accepted_read
      @content_connection.with_lock do
        unless @content_connection.enabled && SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled
          raise AdapterRequestBoundary::Error.new("temporarily_unavailable")
        end
        payload = yield
        # Preserve baseline accepted-read diagnostics without making authentication
        # or failed validation a presence write. Failed serialization rolls back.
        values = { last_seen_at: Time.zone.now, updated_at: Time.zone.now }
        adapter_id = request.headers["X-DiscussionBridge-Adapter"]
        adapter_version = request.headers["X-DiscussionBridge-Adapter-Version"]
        if adapter_id.present?
          values.merge!(adapter_id: adapter_id.dup.force_encoding(Encoding::UTF_8),
                        adapter_version: adapter_version.dup.force_encoding(Encoding::UTF_8))
        end
        @content_connection.update_columns(values)
        payload
      end
    end
  end
end
