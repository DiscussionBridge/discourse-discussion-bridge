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
      render json: result.to_h.merge(core_fallback: false), status: status_for(result.outcome)
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, ArgumentError
      render json: rejection("invalid_request"), status: :unprocessable_entity
    end

    def index
      page = Integer(params[:page].presence || 1, exception: false)
      raise Discourse::InvalidParameters.new(:page) unless page&.between?(1, MAX_PAGE)

      records = scoped_records
      snapshot = AdapterFeedSnapshot.capture(records)
      token = params[:snapshot].presence
      if page > 1 && token.blank?
        raise Discourse::InvalidParameters.new(:snapshot)
      end
      if token && !AdapterFeedSnapshot.valid?(token, connection: @content_connection, snapshot: snapshot)
        raise Discourse::InvalidParameters.new(:snapshot)
      end
      token ||= AdapterFeedSnapshot.issue(connection: @content_connection, snapshot: snapshot)
      page_records = records.distinct.offset((page - 1) * PER_PAGE).limit(PER_PAGE).to_a
      unless AdapterFeedSnapshot.capture(scoped_records) == snapshot
        raise Discourse::InvalidParameters.new(:snapshot)
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
      render json: payload
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
        render json: rejection("connection_scope_denied"), status: :forbidden
        return
      end
      render json: { bridge_record: adapter_record(record) }
    end

    def source_url_proof
      record = DiscussionBridgeBridgeRecord
        .joins(:content_bindings)
        .where(
          discussion_bridge_content_bindings: {
            content_connection_id: @content_connection.id,
            role: "source",
            state: "active",
          },
        )
        .find_by!(resource_id: params[:resource_id])
      unless record_within_connection_scope?(record)
        render json: rejection("connection_scope_denied"), status: :forbidden
        return
      end
      proof = SourceUrlProof.call(
        connection: @content_connection,
        record: record,
        from_url: params.require(:from_url),
        to_url: params.require(:to_url),
      )
      render json: { source_url_proof: proof }
    rescue ActionController::ParameterMissing, ArgumentError
      render json: rejection("invalid_source_url_proof"), status: :unprocessable_entity
    end

    def acknowledge
      input = params.require(:acknowledgement)
      outcome = input.fetch(:outcome).to_s
      raise ArgumentError, "invalid outcome" if DiscussionBridgeBridgeRecord::DELIVERY_OUTCOMES.exclude?(outcome)
      error_code = input[:error_code].to_s.presence
      error_detail = input[:error_detail].to_s.presence
      raise ArgumentError, "error code is required" if outcome == "failed" && error_code.nil?
      if outcome != "failed" && (error_code || error_detail)
        raise ArgumentError, "successful acknowledgement cannot include an error"
      end
      raise ArgumentError, "invalid error code" if error_code&.bytesize.to_i > 64
      raise ArgumentError, "invalid error detail" if error_detail&.bytesize.to_i > 1000
      exact_retry = false
      record = nil
      DiscussionBridgeBridgeRecord.transaction do
        @content_connection = DiscussionBridgeContentConnection.lock.find(@content_connection.id)
        record = DiscussionBridgeBridgeRecord.joins(:content_bindings).lock
          .where(discussion_bridge_content_bindings: {
            content_connection_id: @content_connection.id, role: "presentation", state: "active",
          }).find_by!(resource_id: params[:resource_id], direction: "from_discourse")
        topic = record.topic
        topic&.lock!
        topic&.first_post&.lock!
        topic&.reload
        topic&.association(:tags)&.reload
        publication = TopicPublicationState.for_revocation(
          connection: @content_connection,
          record: record,
        )
        raise ArgumentError, "publication revision changed" unless
          input.fetch(:publication_revision) == publication.publication_revision
        eligible = publication.eligibility.fetch(:eligible)
        if eligible
          ready = publication.destination.fetch("state") == "ready"
          allowed = ready ? %w[created updated unchanged failed] : %w[held failed]
          raise ArgumentError, "invalid delivery outcome" if allowed.exclude?(outcome)
          raise ArgumentError, "source revision changed" unless
            input.fetch(:source_revision) == publication.source_revision
          raise ArgumentError, "mapping revision changed" unless
            input.fetch(:mapping_revision) == publication.destination.fetch("mapping_revision")
          raise ArgumentError, "destination plan changed" unless
            TopicPublicationState.destination_matches?(input.fetch(:destination), publication.destination)
        elsif !%w[held unpublished failed].include?(outcome)
          raise ArgumentError, "ineligible publication must be held or unpublished"
        end
        binding = record.active_binding("presentation")
        native_destination = input.fetch(:native_destination)
        raise ArgumentError, "native destination changed" unless
          native_destination[:external_id] == binding&.external_id &&
          native_destination[:canonical_url] == binding&.canonical_url

        destination_state = if outcome == "failed"
          "failed"
        elsif %w[held unpublished].include?(outcome)
          "held"
        else
          "healthy"
        end
        applied_destination = eligible ? publication.destination : {
          "state" => "held",
          "reasons" => [publication.eligibility.fetch(:reason)],
        }
        exact_retry = record.last_delivery_outcome == outcome &&
          record.destination_state == destination_state &&
          record.last_delivery_error_code == error_code && record.last_delivery_error_detail == error_detail &&
          record.attempted_publication_revision == publication.publication_revision &&
          record.attempted_mapping_revision.to_s == publication.destination["mapping_revision"].to_s &&
          TopicPublicationState.destination_matches?(record.attempted_destination, applied_destination) &&
          (outcome == "failed" || record.acknowledged_publication_revision == publication.publication_revision)
        unless exact_retry
          attributes = {
            destination_state: destination_state,
            acknowledged_at: Time.zone.now,
            last_delivery_outcome: outcome,
            last_delivery_attempt_at: Time.zone.now,
            delivery_attempt_count: record.delivery_attempt_count + 1,
            last_delivery_error_code: error_code,
            last_delivery_error_detail: error_detail,
            attempted_publication_revision: publication.publication_revision,
            attempted_mapping_revision: publication.destination["mapping_revision"],
            attempted_destination: applied_destination,
          }
          unless outcome == "failed"
            attributes.merge!(
              acknowledged_source_revision: publication.source_revision,
              acknowledged_publication_revision: publication.publication_revision,
              acknowledged_mapping_revision: publication.destination["mapping_revision"],
              acknowledged_destination: applied_destination,
              pending_publication_revision: nil,
              pending_mapping_revision: nil,
              pending_destination: {},
            )
            attributes[:publication_program] = "forum_sync" if
              record.publication_program == "forum_sync_pending"
          end
          record.update!(attributes)
        end
      end
      render json: {
        outcome: exact_retry ? "resolved" : "acknowledged",
        resource_id: record.resource_id,
        destination_state: record.destination_state,
        acknowledged_source_revision: record.acknowledged_source_revision,
        acknowledged_publication_revision: record.acknowledged_publication_revision,
        acknowledged_mapping_revision: record.acknowledged_mapping_revision,
        delivery_attempt_count: record.delivery_attempt_count,
      }
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid,
           ActiveRecord::RecordNotFound, ArgumentError => error
      render json: {
        outcome: "rejected", reason: acknowledgement_reason(error), errors: [error.message],
      }, status: :unprocessable_entity
    end

    private

    def acknowledgement_reason(error)
      {
        "publication revision changed" => "publication_revision_changed",
        "source revision changed" => "source_revision_changed",
        "mapping revision changed" => "destination_mapping_changed",
        "destination plan changed" => "destination_plan_changed",
        "native destination changed" => "native_destination_changed",
        "invalid delivery outcome" => "invalid_delivery_outcome",
      }.fetch(error.message, "invalid_acknowledgement")
    end

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

    def ensure_json_request
      raise Discourse::InvalidParameters.new(:format) unless request.format.json?
    end

    def ensure_enabled
      return if SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled

      render json: rejection("endpoint_disabled"), status: :service_unavailable
    end

    def authenticate_connection
      identity = action_name == "acknowledge" ? :catalog : :claim
      @content_connection = ContentConnectionAuthenticator.call(request, identity: identity)
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
        delivery: record.direction == "from_discourse" ? {
          state: record.destination_state,
          acknowledged_source_revision: record.acknowledged_source_revision,
          acknowledged_publication_revision: record.acknowledged_publication_revision,
          acknowledged_mapping_revision: record.acknowledged_mapping_revision,
          acknowledged_destination: record.acknowledged_destination,
          pending_publication_revision: record.pending_publication_revision,
          pending_mapping_revision: record.pending_mapping_revision,
          pending_destination: record.pending_destination,
          acknowledged_at: record.acknowledged_at&.iso8601(6),
          last_outcome: record.last_delivery_outcome,
          publication_program: record.publication_program,
          attempt_count: record.delivery_attempt_count,
          last_attempt_at: record.last_delivery_attempt_at&.iso8601(6),
          last_error_code: record.last_delivery_error_code,
          last_error_detail: record.last_delivery_error_detail,
        } : nil,
        bindings: record.content_bindings.where(content_connection_id: @content_connection.id).map do |binding|
          {
            role: binding.role,
            state: binding.state,
            external_id: binding.external_id,
            canonical_url: binding.canonical_url,
            native_materialization: binding.native_materialization,
            url_migration: latest_url_migration(binding),
          }
        end,
      }
    end

    def latest_url_migration(binding)
      return nil if binding.role == "presentation" && !binding.native_materialization

      history_class = binding.role == "source" ? DiscussionBridgeSourceUrlHistory : DiscussionBridgePresentationUrlHistory
      history = history_class
        .where(content_binding_id: binding.id)
        .order(id: :desc)
        .first
      return nil unless history

      {
        old_url: history.old_canonical_url,
        new_url: history.new_canonical_url,
        redirect_status: history.redirect_status,
        verified_at: history.verified_at.iso8601(6),
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
