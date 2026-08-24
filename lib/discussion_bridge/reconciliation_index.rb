# frozen_string_literal: true

require "json"

module DiscussionBridge
  class ReconciliationIndex
    PER_PAGE = 25
    MAX_PAGE = 10_000
    MAX_QUERY_BYTES = 200
    STALE_RESERVATION_AGE = 15.minutes
    SEVERITIES = %w[critical high medium].freeze
    RECOMMENDATIONS = {
      "duplicate_source" => "review_duplicate_identity", "duplicate_topic" => "review_duplicate_topic",
      "retry_authorized" => "await_adapter_retry", "failed_mapping" => "authorize_retry",
      "stale_reservation" => "authorize_retry", "topic_missing" => "restore_or_retire_mapping",
      "topic_deleted" => "restore_or_retire_mapping", "first_post_missing" => "restore_or_retire_mapping",
      "first_post_deleted" => "restore_or_retire_mapping", "system_authored" => "review_authorship",
      "lane_denied" => "review_lane_policy", "lane_policy_invalid" => "review_lane_policy",
      "category_drift" => "review_policy_drift", "tag_drift" => "review_policy_drift",
      "actor_drift" => "review_policy_drift", "visibility_drift" => "review_policy_drift",
      "effective_visibility_drift" => "review_policy_drift",
      "topic_archetype_mismatch" => "restore_or_retire_mapping",
      "topic_closed" => "review_topic_state", "topic_archived" => "review_topic_state",
    }.freeze
    ACTIONS = {
      "retry_authorized" => "revoke_retry",
      "failed_mapping" => "authorize_retry",
      "stale_reservation" => "authorize_retry",
    }.freeze

    def self.call(query: nil, severity: nil, page: 1, now: Time.zone.now)
      new(query: query, severity: severity, page: page, now: now).call
    end

    def initialize(query:, severity:, page:, now:)
      @query = query.to_s.strip
      raise ArgumentError, "query is too large" if @query.bytesize > MAX_QUERY_BYTES
      @severity = severity.presence&.to_s
      raise ArgumentError, "invalid severity" if @severity && !SEVERITIES.include?(@severity)
      parsed_page = Integer(page.presence || 1, exception: false)
      raise ArgumentError, "invalid page" unless parsed_page&.between?(1, MAX_PAGE)
      @page = parsed_page
      @now = now
      @connection = ActiveRecord::Base.connection
    end

    def call
      filtered = filtered_issue_sql
      result = @connection.exec_query(<<~SQL).first
        #{issue_ctes},
        filtered_rows AS (#{filtered}),
        summary AS (
          SELECT COUNT(*) AS total,
            COUNT(*) FILTER (WHERE severity = 'critical') AS critical,
            COUNT(*) FILTER (WHERE severity = 'high') AS high,
            COUNT(*) FILTER (WHERE severity = 'medium') AS medium
          FROM filtered_rows
        ),
        page_rows AS (
          SELECT * FROM filtered_rows
          ORDER BY
            CASE severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
            mapping_id DESC,
            code ASC
          LIMIT #{PER_PAGE} OFFSET #{(@page - 1) * PER_PAGE}
        )
        SELECT summary.*,
          COALESCE((SELECT jsonb_agg(
            to_jsonb(page_rows)
            ORDER BY
              CASE severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
              mapping_id DESC,
              code ASC
          ) FROM page_rows), '[]'::jsonb) AS items
        FROM summary
      SQL
      rows = result.fetch("items")
      rows = JSON.parse(rows) if rows.is_a?(String)
      total = result.fetch("total").to_i
      {
        query: @query.presence,
        severity: @severity,
        items: rows.map { |row| issue_from_row(row) },
        summary: {
          critical: result.fetch("critical").to_i,
          high: result.fetch("high").to_i,
          medium: result.fetch("medium").to_i,
          total: total,
        },
        pagination: {
          page: @page, per_page: PER_PAGE, total: total,
          pages: [(total.to_f / PER_PAGE).ceil, 1].max,
        },
      }
    end

    private

    def issue_ctes
      <<~SQL
        WITH policy_rows(lane, category_id, tags) AS (#{policy_rows_sql}),
        mapping_base AS (
          SELECT mappings.*, topics.id AS topic_record_id, topics.deleted_at AS topic_deleted_at,
            topics.user_id AS topic_user_id, topics.category_id AS topic_category_id,
            topics.visible AS topic_visible, topics.archetype AS topic_archetype,
            topics.closed AS topic_closed, topics.archived AS topic_archived,
            first_posts.id AS first_post_id,
            first_posts.deleted_at AS first_post_deleted_at,
            policies.category_id AS expected_category_id, policies.tags AS expected_tags,
            #{policy_missing_sql} AS policy_missing,
            COUNT(*) OVER (PARTITION BY mappings.source_identity_digest) AS source_count,
            COUNT(*) FILTER (WHERE mappings.topic_id IS NOT NULL)
              OVER (PARTITION BY mappings.topic_id) AS topic_count
          FROM discussion_bridge_connections mappings
          LEFT JOIN topics ON topics.id = mappings.topic_id
          LEFT JOIN posts first_posts ON first_posts.topic_id = topics.id AND first_posts.post_number = 1
          #{policy_join_sql}
        ),
        issue_rows AS (#{issue_union_sql})
      SQL
    end

    def policy_rows_sql
      policies = LanePolicies.parse(SiteSetting.discussion_bridge_lane_policies)
      @lane_policies_configured = policies.any?
      if policies.any?
        policies.map do |policy|
          "SELECT #{@connection.quote(policy[:lane])}::text, #{policy[:category_id].to_i}::bigint, " \
            "#{@connection.quote(policy[:tags].sort.to_json)}::jsonb"
        end.join(" UNION ALL ")
      else
        tags = list_values(SiteSetting.discussion_bridge_effective_tags).sort
        "SELECT NULL::text, #{SiteSetting.discussion_bridge_effective_category_id.to_i}::bigint, " \
          "#{@connection.quote(tags.to_json)}::jsonb"
      end
    rescue LanePolicies::ParseError
      @lane_policy_invalid = true
      @lane_policies_configured = true
      "SELECT NULL::text, NULL::bigint, '[]'::jsonb WHERE FALSE"
    end

    def policy_join_sql
      @lane_policies_configured ?
        "LEFT JOIN policy_rows policies ON policies.lane = mappings.lane" :
        "CROSS JOIN policy_rows policies"
    end

    def policy_missing_sql
      return "TRUE" if @lane_policy_invalid
      return "policies.lane IS NULL" if @lane_policies_configured
      "FALSE"
    end

    def issue_union_sql
      unions = []
      unions << issue_select("source_count > 1", "duplicate_source", "critical")
      unions << issue_select("topic_id IS NOT NULL AND topic_count > 1", "duplicate_topic", "critical")
      unions << issue_select("retry_authorized_at IS NOT NULL", "retry_authorized", "medium")
      unions << issue_select("state = 'failed' AND retry_authorized_at IS NULL", "failed_mapping", "medium")
      unions << issue_select(
        "state = 'reserved' AND retry_authorized_at IS NULL AND updated_at < #{@connection.quote(@now - STALE_RESERVATION_AGE)}",
        "stale_reservation", "medium",
      )
      unions << issue_select("state = 'complete' AND topic_record_id IS NULL", "topic_missing", "high")
      unions << issue_select("topic_deleted_at IS NOT NULL", "topic_deleted", "high")
      unions << issue_select(
        "topic_record_id IS NOT NULL AND topic_archetype IS DISTINCT FROM #{@connection.quote(Archetype.default)}",
        "topic_archetype_mismatch", "high",
      )
      unions << issue_select("topic_record_id IS NOT NULL AND topic_closed IS TRUE", "topic_closed", "high")
      unions << issue_select("topic_record_id IS NOT NULL AND topic_archived IS TRUE", "topic_archived", "high")
      unions << issue_select(
        "state = 'complete' AND topic_record_id IS NOT NULL AND first_post_id IS NULL",
        "first_post_missing", "high",
      )
      unions << issue_select("first_post_deleted_at IS NOT NULL", "first_post_deleted", "high")
      unions << issue_select(
        "topic_user_id IS NOT NULL AND (effective_actor_id = #{Discourse::SYSTEM_USER_ID.to_i} " \
          "OR topic_user_id = #{Discourse::SYSTEM_USER_ID.to_i})",
        "system_authored", "medium",
      )
      unions << issue_select(
        "topic_user_id IS NOT NULL AND policy_missing",
        @lane_policy_invalid ? "lane_policy_invalid" : "lane_denied", "high",
      )
      unions << issue_select(
        "NOT policy_missing AND topic_user_id IS NOT NULL AND topic_category_id IS DISTINCT FROM expected_category_id",
        "category_drift", "medium",
      )
      unions << issue_select(<<~SQL.squish, "tag_drift", "medium")
        NOT policy_missing AND topic_user_id IS NOT NULL AND
        COALESCE((SELECT jsonb_agg(tags.name ORDER BY tags.name)
          FROM topic_tags JOIN tags ON tags.id = topic_tags.tag_id
          WHERE topic_tags.topic_id = mapping_base.topic_id), '[]'::jsonb)
          IS DISTINCT FROM expected_tags
      SQL
      expected_actor_id = User.find_by(
        username_lower: SiteSetting.discussion_bridge_service_username.to_s.downcase,
      )&.id
      actor_condition = if expected_actor_id
        "topic_user_id IS NOT NULL AND (effective_actor_id IS DISTINCT FROM #{expected_actor_id.to_i} " \
          "OR topic_user_id IS DISTINCT FROM #{expected_actor_id.to_i})"
      else
        "topic_user_id IS NOT NULL"
      end
      unions << issue_select(actor_condition, "actor_drift", "medium")
      unions << issue_select("topic_visible IS TRUE", "visibility_drift", "medium")
      unions << issue_select(
        "topic_record_id IS NOT NULL AND effective_visibility IS DISTINCT FROM 'unlisted'",
        "effective_visibility_drift", "medium",
      )
      unions.join(" UNION ALL ")
    end

    def issue_select(condition, code, severity)
      <<~SQL.squish
        SELECT id AS mapping_id, #{@connection.quote(code)}::text AS code,
          #{@connection.quote(severity)}::text AS severity, connection_id,
          canonical_source_url, source_identity_digest, topic_id, lane, state, updated_at
        FROM mapping_base WHERE #{condition}
      SQL
    end

    def filtered_issue_sql
      conditions = []
      conditions << "severity = #{@connection.quote(@severity)}" if @severity
      if @query.present?
        pattern = @connection.quote("%#{ActiveRecord::Base.sanitize_sql_like(@query.downcase)}%")
        conditions << <<~SQL.squish
          LOWER(CONCAT_WS(' ', mapping_id, code, severity, connection_id,
            canonical_source_url, source_identity_digest, topic_id, lane, state)) LIKE #{pattern}
        SQL
      end
      "SELECT * FROM issue_rows#{conditions.any? ? " WHERE #{conditions.join(" AND ")}" : ""}"
    end

    def issue_from_row(row)
      code = row.fetch("code")
      action = ACTIONS[code]
      {
        id: "mapping-#{row.fetch("mapping_id")}-#{code}", mapping_id: row.fetch("mapping_id").to_i,
        code: code, severity: row.fetch("severity"), recommendation: RECOMMENDATIONS.fetch(code),
        action: action, action_label: action ? "discussion_bridge.admin.#{action}" : nil,
        connection_id: row["connection_id"], source_url: row["canonical_source_url"],
        source_digest: row["source_identity_digest"], topic_id: row["topic_id"]&.to_i,
        lane: row["lane"], mapping_state: row["state"], updated_at: row["updated_at"],
      }
    end

    def list_values(value)
      values = value.is_a?(String) ? value.split("|") : Array(value)
      values.map { |entry| entry.to_s.strip }.reject(&:empty?).uniq
    end
  end
end
