# frozen_string_literal: true

require "base64"

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
    PUBLICATION_CONTRACT = "0.3.0-alpha.1"
    CHUNK_BYTES = 32_768
    MAX_METADATA_BYTES = 2 * 1024 * 1024

    rescue_from SourceEdition::Unavailable do
      render json: rejection("source_unavailable"), status: :conflict
    end
    rescue_from SourceEdition::InvalidForumName do
      render json: rejection("invalid_forum_name"), status: :unprocessable_entity
    end

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
      lane_resolution =
        LanePolicies.resolve(value: SiteSetting.discussion_bridge_lane_policies, lane: data[:lane])
      authority =
        ForumAuthority.call(
          actor: actor,
          category_id:
            lane_resolution.category_id || @content_connection.default_category_id ||
              SiteSetting.discussion_bridge_effective_category_id,
          tags: lane_resolution.tags || SiteSetting.discussion_bridge_effective_tags,
        ) if actor
      policy =
        PolicyEvaluator.call(
          request: policy_request(data),
          settings:
            PolicyEvaluator::Settings.new(
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
      result =
        BridgeRecordResolver.call(connection: @content_connection, request: data, policy: policy)
      payload =
        result.to_h.reject do |key, value|
          value.nil? && %i[source_revision source_publication_outcome].include?(key)
        end
      render json: payload.merge(core_fallback: false), status: status_for(result.outcome)
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, ArgumentError
      render json: rejection("invalid_request"), status: :unprocessable_entity
    end

    def index
      negotiate_publication_contract
      page = Integer(params[:page].presence || 1, exception: false)
      raise Discourse::InvalidParameters.new(:page) unless page&.between?(1, MAX_PAGE)

      records = scoped_records
      snapshot = AdapterFeedSnapshot.capture(records)
      token = params[:snapshot].presence
      raise Discourse::InvalidParameters.new(:snapshot) if page > 1 && token.blank?
      if token &&
           !AdapterFeedSnapshot.valid?(token, connection: @content_connection, snapshot: snapshot)
        raise Discourse::InvalidParameters.new(:snapshot)
      end
      token ||= AdapterFeedSnapshot.issue(connection: @content_connection, snapshot: snapshot)
      page_records = records.distinct.offset((page - 1) * PER_PAGE).limit(PER_PAGE).to_a
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
      render_metadata(payload) do
        unless AdapterFeedSnapshot.capture(scoped_records) == snapshot
          raise Discourse::InvalidParameters.new(:snapshot)
        end
      end
    end

    def show
      negotiate_publication_contract
      record = scoped_record
      unless record_within_connection_scope?(record)
        render json: rejection("connection_scope_denied"), status: :forbidden
        return
      end
      render_metadata(bridge_record: adapter_record(record))
    end

    def content
      record = scoped_record
      unless record_within_connection_scope?(record)
        render json: rejection("connection_scope_denied"), status: :forbidden
        return
      end
      unless record.direction == "from_discourse" && record.state == "healthy"
        raise SourceEdition::Unavailable
      end
      edition = SourceEdition.for_topic(record.topic_id)
      raise SourceEdition::Unavailable unless edition && edition.content_html.present?
      expected = params[:edition]
      unless expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/)
        raise Discourse::InvalidParameters.new(:edition)
      end
      if expected != edition.source.fetch(:edition)
        render json: rejection("source_edition_changed"), status: :conflict
        return
      end
      raw_offset = params[:offset]
      unless raw_offset.is_a?(String) && raw_offset.match?(/\A(?:0|[1-9]\d{0,15})\z/)
        raise Discourse::InvalidParameters.new(:offset)
      end
      offset = raw_offset.to_i
      bytes = edition.content_html.b
      if offset >= bytes.bytesize || offset > 9_007_199_254_740_991
        raise Discourse::InvalidParameters.new(:offset)
      end
      chunk = bytes.byteslice(offset, CHUNK_BYTES)
      next_offset = offset + chunk.bytesize
      render json: {
               resource_id: record.resource_id,
               edition: edition.source.fetch(:edition),
               offset: offset,
               total_bytes: bytes.bytesize,
               content_sha256: Digest::SHA256.hexdigest(bytes),
               chunk_base64: Base64.strict_encode64(chunk),
               next_offset: next_offset == bytes.bytesize ? nil : next_offset,
             }
    end

    private

    def negotiate_publication_contract
      value = params[:publication_contract]
      unless value.nil? || value == PUBLICATION_CONTRACT
        raise Discourse::InvalidParameters.new(:publication_contract)
      end
      @publication_contract = value == PUBLICATION_CONTRACT
    end

    def render_metadata(payload)
      json = payload.to_json
      yield if block_given?
      if @publication_contract && json.bytesize > MAX_METADATA_BYTES
        render json: rejection("metadata_too_large"), status: :payload_too_large
      else
        render json: json
      end
    end

    def scoped_record
      DiscussionBridgeBridgeRecord
        .joins(:content_bindings)
        .where(
          discussion_bridge_content_bindings: {
            content_connection_id: @content_connection.id,
            state: "active",
          },
        )
        .find_by!(resource_id: params[:resource_id])
    end

    def scoped_records
      records =
        DiscussionBridgeBridgeRecord
          .joins(:content_bindings)
          .where(
            discussion_bridge_content_bindings: {
              content_connection_id: @content_connection.id,
              state: "active",
            },
          )
          .where(direction: @content_connection.allowed_directions)
          .includes(topic: :first_post)
          .order(id: :asc)
      records =
        if Array(@content_connection.allowed_lanes).empty?
          records.where(lane: [nil, ""])
        else
          records.where(lane: @content_connection.allowed_lanes)
        end
      origin_patterns =
        Array(@content_connection.allowed_origins).map do |origin|
          "#{ActiveRecord::Base.sanitize_sql_like(origin)}/%"
        end
      origin_clause =
        Array.new(
          origin_patterns.length,
          "discussion_bridge_content_bindings.canonical_url LIKE ?",
        ).join(" OR ")
      records.where(origin_clause, *origin_patterns)
    end

    def ensure_json_request
      raise Discourse::InvalidParameters.new(:format) unless request.format.json?
    end

    def ensure_enabled
      if SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled
        return
      end

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
      edition = SourceEdition.for_topic(record.topic_id) if record.direction == "from_discourse"
      source = edition&.source&.dup
      withdrawn = record.direction == "from_discourse" && !edition
      raise SourceEdition::Unavailable if withdrawn && !@publication_contract
      if withdrawn
        source = {
          status: "withdrawn",
          reason: "source_unavailable",
          edition: SourceEdition.withdrawn_edition(record),
        }
      elsif @publication_contract && source
        source[:status] = "active"
        source[:content] = {
          bytes: edition.content_html.bytesize,
          sha256: Digest::SHA256.hexdigest(edition.content_html),
          path: "/discussion-bridge/v1/bridge-records/#{record.resource_id}/content.json",
          chunk_bytes: CHUNK_BYTES,
        }
      end
      {
        resource_id: record.resource_id,
        direction: record.direction,
        state: record.state,
        title: withdrawn ? "Source publication withdrawn" : edition&.title || record.title,
        topic_id: record.topic_id,
        topic_url: withdrawn ? Topic.url(record.topic_id, nil) : edition&.topic_url || topic&.url,
        source_authors: withdrawn ? [] : record.source_authors,
        primary_source_author_id: withdrawn ? nil : record.primary_source_author_id,
        content_html: @publication_contract ? nil : edition&.content_html,
        source: source,
        bindings:
          record
            .content_bindings
            .where(content_connection_id: @content_connection.id)
            .map do |binding|
              {
                role: binding.role,
                state: binding.state,
                external_id: binding.external_id,
                canonical_url: binding.canonical_url,
                native_materialization: binding.native_materialization,
                presentation_mode: binding.presentation_mode,
              }
            end,
      }
    end

    def record_within_connection_scope?(record)
      binding =
        record.content_bindings.find do |candidate|
          candidate.content_connection_id == @content_connection.id && candidate.state == "active"
        end
      binding && @content_connection.allows_direction?(record.direction) &&
        @content_connection.allows_lane?(record.lane) &&
        @content_connection.allows_origin?(binding.canonical_url)
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
