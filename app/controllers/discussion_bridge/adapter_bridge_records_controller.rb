# frozen_string_literal: true

module DiscussionBridge
  class AdapterBridgeRecordsController < AdapterController

    PER_PAGE = AdapterProtocolRecords::PER_PAGE
    MAX_PAGE = AdapterProtocolRecords::MAXIMUM_PAGE

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
        render_protocol_json(resolve_payload(result), status: status_for(result.outcome))
      end
    end

    def index
      page = Integer(params[:page].presence || 1, exception: false)
      raise AdapterRequestBoundary::Error, "malformed_value" unless page&.between?(1, MAX_PAGE)

      eligible = scoped_records.distinct
      total = eligible.count(:id)
      page_ids = eligible.reorder(id: :asc).offset((page - 1) * PER_PAGE).limit(PER_PAGE).pluck(:id)
      latest_revisions = latest_source_revisions(page_ids)
      page_records = DiscussionBridgeBridgeRecord.where(id: page_ids)
        .includes(topic: :first_post, content_bindings: :content_connection)
        .index_by(&:id).values_at(*page_ids).compact
        .select { |record| record_within_connection_scope?(record) }
      payload = {
        records: page_records.map { |record| adapter_record(record, latest_revisions[record.id]) },
        page: page,
        total_pages: [(total.to_f / PER_PAGE).ceil, 1].max,
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
      if (withdrawal = active_withdrawal_work(record))
        render_protocol_json({ bridge_record: cleanup_adapter_record(record, withdrawal) })
        return
      end
      unless record_within_connection_scope?(record)
        render_protocol_error("scope_denied")
        return
      end
      unless protocol_ready_record?(record)
        render_protocol_error("temporarily_unavailable")
        return
      end
      render_protocol_json({ bridge_record: adapter_record(record) })
    end

    def source_url_proof
      record = DiscussionBridgeBridgeRecord
        .joins(:content_bindings)
        .where(
          direction: "to_discourse",
          discussion_bridge_content_bindings: {
            content_connection_id: @content_connection.id,
            role: "source",
            state: "active",
          },
        ).distinct.find_by!(resource_id: params[:resource_id])
      proof = SourceUrlProof.call(
        connection: @content_connection,
        record: record,
        from_url: params.require(:from_url),
        to_url: params.require(:to_url),
      )
      render_protocol_json(proof)
    end

    private

    def allow_disabled_connection?
      action_name == "show"
    end

    def scoped_records
      records = DiscussionBridgeBridgeRecord
        .joins(:content_bindings)
        .where(discussion_bridge_content_bindings: { content_connection_id: @content_connection.id, state: "active" })
        .where(direction: @content_connection.allowed_directions)
        .where(
          "discussion_bridge_bridge_records.direction = 'from_discourse' OR " \
            "discussion_bridge_bridge_records.source_revision IS NOT NULL",
        )
        .joins(:topic)
        .where(currently_disclosable_record_sql)
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

    def currently_disclosable_record_sql
      source_conditions = <<~SQL.squish
        discussion_bridge_bridge_records.direction <> 'from_discourse' OR (
          discussion_bridge_bridge_records.state <> 'attention' AND
          topics.deleted_at IS NULL AND topics.visible = TRUE AND
          EXISTS (
            SELECT 1 FROM posts
            WHERE posts.topic_id = discussion_bridge_bridge_records.topic_id
              AND posts.post_number = 1 AND posts.deleted_at IS NULL
          ) AND
          NOT EXISTS (
            SELECT 1 FROM discussion_bridge_publication_overrides AS publication_override
            WHERE publication_override.content_connection_id = :connection_id
              AND publication_override.topic_id = discussion_bridge_bridge_records.topic_id
              AND publication_override.decision = 'exclude'
          )
          #{network_inventory_sql}
        )
      SQL
      ActiveRecord::Base.sanitize_sql_array([source_conditions, { connection_id: @content_connection.id }])
    end

    def network_inventory_sql
      return "" unless @content_connection.network_enabled

      <<~SQL.squish.prepend(" AND ")
        topics.archetype <> 'private_message' AND
        NOT EXISTS (
          SELECT 1 FROM categories
          WHERE categories.id = topics.category_id AND categories.read_restricted = TRUE
        ) AND
        NOT EXISTS (
          SELECT 1 FROM discussion_bridge_bridge_records AS received_record
          WHERE received_record.topic_id = discussion_bridge_bridge_records.topic_id
            AND received_record.direction = 'to_discourse'
            AND received_record.state = 'healthy'
            AND received_record.network_provenance IS NOT NULL
        )
      SQL
    end

    def active_withdrawal_work(record)
      candidates = @content_connection.publication_works.includes(:source_revocation_record).where(
        bridge_record_id: record.id,
        action: %w[hold unpublish],
        state: %w[leased awaiting_deployment awaiting_verification],
      ).where("lease_expires_at > ?", Time.zone.now).to_a.select do |work|
        revocation = work.source_revocation_record
        revocation && revocation.bridge_record_id == record.id &&
          (revocation.restored_at.nil? || revocation.reason == "policy_removed")
      end
      raise AdapterRequestBoundary::Error, "reconciliation_required" if candidates.many?

      candidates.first
    end

    def cleanup_adapter_record(record, work)
      topic = record.topic
      first_post = topic&.first_post
      created_at = record.source_created_at || record.created_at
      updated_at = work.source_revocation_record&.effective_at || work.created_at
      {
        resource_id: record.resource_id,
        direction: record.direction,
        state: record.state,
        title: topic&.title || record.title,
        topic_id: record.topic_id,
        topic_url: topic&.url,
        source_revision: work.source_revision,
        source_revision_sequence: work.source_revision_sequence,
        source_created_at: created_at.iso8601(6),
        source_updated_at: updated_at.iso8601(6),
        content_disposition: "complete",
        bindings: record.content_bindings.where(content_connection_id: @content_connection.id).map do |binding|
          adapter_binding(binding, record, first_post, nil, work.presentation_mode)
        end,
      }.compact
    end

    def maximum_json_bytes
      action_name == "create" ? BridgeRecordRequest::MAX_JSON_BYTES : nil
    end

    def allowed_query_fields
      return %w[page] if action_name == "index"
      return %w[from_url to_url] if action_name == "source_url_proof"

      []
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

    def adapter_record(record, persisted_revision = nil)
      topic = record.topic
      first_post = topic&.first_post
      persisted_revision ||= if record.direction == "from_discourse"
        record.source_revisions.order(source_revision_sequence: :desc).first
      end
      revision = record.direction == "from_discourse" ?
        discourse_revision(persisted_revision, first_post) : stored_revision(record)
      source_title = persisted_revision&.title || topic&.title
      source_content = persisted_revision&.content_html || first_post&.cooked
      payload = {
        resource_id: record.resource_id,
        direction: record.direction,
        state: record.state,
        title: record.direction == "from_discourse" ? source_title : record.title,
        topic_id: record.topic_id,
        topic_url: topic&.url,
        source_revision: revision.fetch(:source_revision),
        source_revision_sequence: revision.fetch(:source_revision_sequence),
        source_created_at: revision.fetch(:source_created_at),
        source_updated_at: revision.fetch(:source_updated_at),
        bindings: record.content_bindings.where(content_connection_id: @content_connection.id).map do |binding|
          adapter_binding(binding, record, first_post, persisted_revision)
        end,
      }
      if record.direction == "from_discourse"
        payload[:content_disposition] = "complete"
        payload[:content_transport] = inline_transport(source_content) if
          source_content.bytesize <= BridgeRecordRequest::MAX_CONTENT_HTML_BYTES
      elsif record.content_disposition.present?
        payload[:content_disposition] = record.content_disposition
      end
      payload.compact
    end

    def record_within_connection_scope?(record)
      binding = record.content_bindings.find do |candidate|
        candidate.content_connection_id == @content_connection.id && candidate.state == "active"
      end
      binding && @content_connection.allows_direction?(record.direction) &&
        @content_connection.allows_lane?(record.lane) &&
        @content_connection.allows_origin?(binding.canonical_url) &&
        source_record_currently_disclosable?(record)
    end

    def source_record_currently_disclosable?(record)
      return true unless record.direction == "from_discourse"

      SourceRevisionMaterializer.unavailability_reason(
        record: record,
        connection: @content_connection,
      ).nil?
    end

    def discourse_revision(persisted, first_post)
      return {
        source_revision: persisted.source_revision,
        source_revision_sequence: persisted.source_revision_sequence,
        source_created_at: persisted.source_created_at.iso8601(6),
        source_updated_at: persisted.source_updated_at.iso8601(6),
      } if persisted

      {
        source_revision: "post:#{first_post.id}:version:#{first_post.version}",
        source_revision_sequence: first_post.version,
        source_created_at: first_post.created_at.iso8601(6),
        source_updated_at: first_post.updated_at.iso8601(6),
      }
    end

    def stored_revision(record)
      {
        source_revision: record.source_revision,
        source_revision_sequence: record.source_revision_sequence,
        source_created_at: record.source_created_at_wire.presence || record.source_created_at.iso8601(6),
        source_updated_at: record.source_updated_at_wire.presence || record.source_updated_at.iso8601(6),
      }
    end

    def inline_transport(content_html)
      {
        mode: "inline",
        media_type: "text/html; charset=utf-8",
        byte_length: content_html.bytesize,
        sha256: Digest::SHA256.hexdigest(content_html),
        content_html: content_html,
      }
    end

    def adapter_binding(binding, record, first_post, persisted_revision, presentation_mode = nil)
      dynamic = record.direction == "to_discourse"
      payload = {
        binding_id: binding.binding_id,
        connection_id: binding.content_connection.public_id,
        role: binding.role,
        state: external_binding_state(binding.state),
        external_id: binding.external_id,
        canonical_url: binding.canonical_url,
        presentation_mode: presentation_mode || binding.presentation_mode ||
          source_presentation_mode(record, persisted_revision),
        applied_source_revision: binding.applied_source_revision,
        publication_revision: binding.publication_revision || (dynamic ? "post:#{first_post.id}:version:#{first_post.version}" : nil),
        content_disposition: binding.content_disposition,
        synchronized_at: binding.synchronized_at_wire.presence || binding.synchronized_at&.iso8601(6),
        deployment_state: dynamic ? "not_required" : binding.deployment_state,
        deployed_at: binding.deployed_at_wire.presence || binding.deployed_at&.iso8601(6),
        verification_state: dynamic ? "not_required" : binding.verification_state,
        publicly_verified_at: binding.publicly_verified_at_wire.presence || binding.publicly_verified_at&.iso8601(6),
      }
      payload.compact
    end

    def source_presentation_mode(record, persisted_revision = nil)
      revision_mode = persisted_revision&.presentation_mode
      revision_mode ||= record.source_revisions.order(source_revision_sequence: :desc).pick(:presentation_mode)
      return revision_mode if revision_mode.present?

      modes = Array(@content_connection.destination_policies).filter_map do |policy|
        policy.stringify_keys["presentation_mode"]
      end.uniq
      modes.one? ? modes.first : "interactive"
    end

    def latest_source_revisions(record_ids)
      return {} if record_ids.empty?

      DiscussionBridgeSourceRevision.where(bridge_record_id: record_ids)
        .select("DISTINCT ON (bridge_record_id) discussion_bridge_source_revisions.*")
        .order(:bridge_record_id, source_revision_sequence: :desc)
        .index_by(&:bridge_record_id)
    end

    def external_binding_state(state)
      { "prepared" => "pending", "active" => "active", "historical" => "retired" }.fetch(state)
    end

    def protocol_ready_record?(record)
      record.direction == "from_discourse" || (
        record.source_revision.present? && record.source_revision_sequence.present? &&
          record.source_created_at.present? && record.source_updated_at.present?
      )
    end

    def resolve_payload(result)
      common = {
        outcome: result.outcome,
        reason: result.reason,
        resource_id: result.resource_id,
        topic_id: result.topic_id,
        topic_url: result.topic_url,
        direction: result.direction,
      }
      if result.outcome == "reconciliation_required"
        common.merge(conflict_fields: result.conflict_fields || [], core_fallback: false)
      else
        common.merge(
          accepted_source_revision: result.accepted_source_revision,
          accepted_source_revision_sequence: result.accepted_source_revision_sequence,
          core_fallback: false,
        )
      end
    end

    def status_for(outcome)
      return :created if outcome == "created"
      return :ok if outcome == "resolved"
      return :conflict if outcome == "reconciliation_required"

      :unprocessable_entity
    end
  end
end
