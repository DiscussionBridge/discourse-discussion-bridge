# frozen_string_literal: true

module DiscussionBridge
  class BridgeReconciliationIndex
    PER_PAGE = 25
    MAX_PAGE = 10_000
    MAX_RECORDS = 10_000
    SEVERITIES = %w[critical high medium].freeze

    def self.call(query: nil, severity: nil, page: 1)
      new(query: query, severity: severity, page: page).call
    end

    def self.summary
      issues = new(query: nil, severity: nil, page: 1).all_issues
      {
        critical: issues.count { |issue| issue[:severity] == "critical" },
        high: issues.count { |issue| issue[:severity] == "high" },
        medium: issues.count { |issue| issue[:severity] == "medium" },
        total: issues.length,
      }
    end

    def initialize(query:, severity:, page:)
      @query = query.to_s.strip
      raise ArgumentError, "query is too large" if @query.bytesize > 200
      @severity = severity.presence&.to_s
      raise ArgumentError, "invalid severity" if @severity && !SEVERITIES.include?(@severity)
      @page = Integer(page.presence || 1, exception: false)
      raise ArgumentError, "invalid page" unless @page&.between?(1, MAX_PAGE)
    end

    def call
      issues = all_issues
      issues.select! { |issue| issue[:severity] == @severity } if @severity
      if @query.present?
        needle = @query.downcase
        issues.select! { |issue| issue.values.join(" ").downcase.include?(needle) }
      end
      summary = {
        critical: issues.count { |issue| issue[:severity] == "critical" },
        high: issues.count { |issue| issue[:severity] == "high" },
        medium: issues.count { |issue| issue[:severity] == "medium" },
        total: issues.length,
      }
      pages = [(issues.length.to_f / PER_PAGE).ceil, 1].max
      {
        query: @query.presence,
        severity: @severity,
        items: issues.slice((@page - 1) * PER_PAGE, PER_PAGE) || [],
        summary: summary,
        pagination: { page: @page, per_page: PER_PAGE, total: issues.length, pages: pages },
      }
    end

    def all_issues
      issues = []
      records = DiscussionBridgeBridgeRecord
        .includes(topic: :first_post, content_bindings: :content_connection)
        .order(:id)
        .limit(MAX_RECORDS + 1)
        .to_a
      truncated = records.length > MAX_RECORDS
      records = records.first(MAX_RECORDS)
      records.each do |record|
        topic = record.topic
        issues << issue(record, "topic_missing", "critical", "Restore or retire this Bridge Record") unless topic
        if topic
          issues << issue(record, "topic_deleted", "critical", "Restore or retire this Bridge Record") if topic.deleted_at
          first_post = topic.first_post
          issues << issue(record, "first_post_missing", "high", "Restore the Discourse content") unless first_post
          issues << issue(record, "first_post_deleted", "high", "Restore the Discourse content") if first_post&.deleted_at
        end
        active = record.content_bindings.select { |binding| binding.state == "active" }
        expected_role = record.direction == "to_discourse" ? "source" : "presentation"
        if active.empty?
          issues << issue(record, "active_binding_missing", "critical", "Restore one active #{expected_role} binding")
        elsif active.length != 1 || active.first.role != expected_role
          issues << issue(
            record,
            "active_binding_invalid",
            "critical",
            "Retain exactly one active #{expected_role} binding and retire every other active role",
          )
        end
        active.each do |binding|
          issues << issue(record, "connection_disabled", "high", "Enable or migrate the connection") unless binding.content_connection.enabled
          issues << issue(record, "origin_outside_scope", "high", "Correct the binding or connection origin scope") unless
            binding.content_connection.allows_origin?(binding.canonical_url)
        end
        prepared = record.content_bindings.count { |binding| binding.state == "prepared" }
        issues << issue(record, "migration_state_mismatch", "medium", "Complete or cancel the prepared migration") if
          (record.state == "migration") != prepared.positive?
      end
      if truncated
        issues << {
          id: "bridge-record-estate-over-limit",
          bridge_record_id: 0,
          resource_id: nil,
          code: "estate_over_limit",
          severity: "critical",
          recommendation: "Reduce or partition the estate before relying on this bounded report",
          connection_name: nil,
          source_url: nil,
          topic_id: nil,
          direction: nil,
          updated_at: Time.zone.now,
        }
      end
      issues.sort_by { |issue| [["critical", "high", "medium"].index(issue[:severity]), -issue[:bridge_record_id], issue[:code]] }
    end

    private

    def issue(record, code, severity, recommendation)
      binding = record.content_bindings.find { |candidate| candidate.state == "active" }
      {
        id: "bridge-record-#{record.id}-#{code}",
        bridge_record_id: record.id,
        resource_id: record.resource_id,
        code: code,
        severity: severity,
        recommendation: recommendation,
        connection_name: binding&.content_connection&.name,
        source_url: binding&.canonical_url,
        topic_id: record.topic_id,
        direction: record.direction,
        updated_at: record.updated_at,
      }
    end
  end
end
