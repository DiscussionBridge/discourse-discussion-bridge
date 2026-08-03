# frozen_string_literal: true

module DiscussionBridge
  class ReconciliationIndex
    PER_PAGE = 25
    STALE_RESERVATION_AGE = 15.minutes
    SEVERITIES = %w[critical high medium].freeze

    def self.call(query: nil, severity: nil, page: 1, now: Time.zone.now)
      new(query: query, severity: severity, page: page, now: now).call
    end

    def initialize(query:, severity:, page:, now:)
      @query = query.to_s.strip.first(200)
      @severity = SEVERITIES.include?(severity.to_s) ? severity.to_s : nil
      @page = [page.to_i, 1].max
      @now = now
    end

    def call
      issues = duplicate_issues + mapping_issues
      issues.select! { |issue| issue[:severity] == @severity } if @severity
      issues.select! { |issue| searchable(issue).include?(@query.downcase) } if @query.present?
      issues.sort_by! { |issue| [severity_order(issue[:severity]), -issue[:mapping_id].to_i, issue[:code]] }

      total = issues.length
      {
        query: @query.presence,
        severity: @severity,
        items: issues.slice((@page - 1) * PER_PAGE, PER_PAGE) || [],
        summary: summary(issues),
        pagination: {
          page: @page,
          per_page: PER_PAGE,
          total: total,
          pages: [(total.to_f / PER_PAGE).ceil, 1].max,
        },
      }
    end

    private

    def mapping_issues
      DiscussionBridgeConnection.includes(:effective_actor, topic: :tags).flat_map do |mapping|
        issues_for(mapping)
      end
    end

    def issues_for(mapping)
      issues = state_issues(mapping)
      topic = mapping.topic
      return issues + [issue(mapping, "topic_missing", "high", "restore_or_retire_mapping")] if mapping.state == "complete" && !topic
      return issues unless topic

      issues << issue(mapping, "topic_deleted", "high", "restore_or_retire_mapping") if topic.deleted_at.present?
      issues << issue(mapping, "system_authored", "medium", "review_authorship") if system_authored?(mapping, topic)
      issues.concat(policy_issues(mapping, topic))
      issues
    end

    def state_issues(mapping)
      if mapping.retry_authorized_at.present?
        [issue(mapping, "retry_authorized", "medium", "await_adapter_retry", action: "revoke_retry")]
      elsif mapping.state == "failed"
        [issue(mapping, "failed_mapping", "medium", "authorize_retry", action: "authorize_retry")]
      elsif mapping.state == "reserved" && mapping.updated_at < @now - STALE_RESERVATION_AGE
        [issue(mapping, "stale_reservation", "medium", "authorize_retry", action: "authorize_retry")]
      else
        []
      end
    end

    def policy_issues(mapping, topic)
      lane = LanePolicies.resolve(value: SiteSetting.discussion_bridge_lane_policies, lane: mapping.lane)
      return [issue(mapping, lane.reason, "high", "review_lane_policy")] unless lane.allowed

      expected_category_id = lane.category_id || SiteSetting.discussion_bridge_effective_category_id.to_i
      expected_tags = lane.tags || list_values(SiteSetting.discussion_bridge_effective_tags)
      expected_actor = User.find_by(username_lower: SiteSetting.discussion_bridge_service_username.to_s.downcase)
      issues = []
      issues << issue(mapping, "category_drift", "medium", "review_policy_drift") if topic.category_id != expected_category_id
      issues << issue(mapping, "tag_drift", "medium", "review_policy_drift") if topic.tags.map(&:name).sort != expected_tags.sort
      if expected_actor.nil? || mapping.effective_actor_id != expected_actor.id || topic.user_id != expected_actor.id
        issues << issue(mapping, "actor_drift", "medium", "review_policy_drift")
      end
      issues << issue(mapping, "visibility_drift", "medium", "review_policy_drift") if topic.visible
      issues
    end

    def duplicate_issues
      duplicate_group_issues(:source_identity_digest, "duplicate_source", "review_duplicate_identity") +
        duplicate_group_issues(:topic_id, "duplicate_topic", "review_duplicate_topic", exclude_nil: true)
    end

    def duplicate_group_issues(column, code, recommendation, exclude_nil: false)
      scope = DiscussionBridgeConnection.group(column).having("COUNT(*) > 1")
      scope = scope.where.not(column => nil) if exclude_nil
      values = scope.count.keys
      return [] if values.empty?

      DiscussionBridgeConnection.where(column => values).map do |mapping|
        issue(mapping, code, "critical", recommendation)
      end
    end

    def issue(mapping, code, severity, recommendation, action: nil)
      {
        id: "mapping-#{mapping.id}-#{code}",
        mapping_id: mapping.id,
        code: code,
        severity: severity,
        recommendation: recommendation,
        action: action,
        action_label: action ? "discussion_bridge.admin.#{action}" : nil,
        connection_id: mapping.connection_id,
        source_url: mapping.canonical_source_url,
        source_digest: mapping.source_identity_digest,
        topic_id: mapping.topic_id,
        lane: mapping.lane,
        mapping_state: mapping.state,
        updated_at: mapping.updated_at,
      }
    end

    def system_authored?(mapping, topic)
      mapping.effective_actor_id == Discourse::SYSTEM_USER_ID || topic.user_id == Discourse::SYSTEM_USER_ID
    end

    def list_values(value)
      values = value.is_a?(String) ? value.split("|") : Array(value)
      values.map { |entry| entry.to_s.strip }.reject(&:empty?).uniq
    end

    def summary(issues)
      counts = SEVERITIES.to_h { |severity| [severity.to_sym, issues.count { |issue| issue[:severity] == severity }] }
      counts.merge(total: issues.length)
    end

    def severity_order(severity)
      SEVERITIES.index(severity) || SEVERITIES.length
    end

    def searchable(issue)
      issue.values.compact.join(" ").downcase
    end
  end
end
