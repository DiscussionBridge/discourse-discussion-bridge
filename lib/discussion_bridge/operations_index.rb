# frozen_string_literal: true

module DiscussionBridge
  class OperationsIndex
    PER_PAGE = 25
    MAX_PAGE = 10_000
    KINDS = %w[mappings audits].freeze

    def self.call(kind:, query: nil, filter: nil, page: 1)
      new(kind: kind, query: query, filter: filter, page: page).call
    end

    def initialize(kind:, query:, filter:, page:)
      @kind = KINDS.include?(kind.to_s) ? kind.to_s : "mappings"
      @query = query.to_s.strip.first(200)
      @filter = filter.to_s.strip.first(100)
      parsed_page = Integer(page.presence || 1, exception: false)
      raise ArgumentError, "invalid page" unless parsed_page&.between?(1, MAX_PAGE)
      @page = parsed_page
    end

    def call
      scope = @kind == "audits" ? audit_scope : mapping_scope
      total = scope.count
      records = scope.order(created_at: :desc, id: :desc).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

      {
        kind: @kind,
        query: @query.presence,
        filter: @filter.presence,
        items: records.map { |record| @kind == "audits" ? serialize_audit(record) : serialize_mapping(record) },
        pagination: {
          page: @page,
          per_page: PER_PAGE,
          total: total,
          pages: [(total.to_f / PER_PAGE).ceil, 1].max,
        },
      }
    end

    private

    def mapping_scope
      scope = DiscussionBridgeConnection.includes(:effective_actor)
      scope = scope.where(state: @filter) if DiscussionBridgeConnection::STATES.include?(@filter)
      return scope if @query.blank?

      term = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      scope.where(
        "connection_id ILIKE :term OR canonical_source_url ILIKE :term OR source_identity_digest ILIKE :term OR lane ILIKE :term",
        term: term,
      )
    end

    def audit_scope
      scope = DiscussionBridgeAuditEvent.includes(:effective_actor)
      scope = scope.where(outcome: @filter) if @filter.present?
      return scope if @query.blank?

      term = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      scope.where(
        "connection_id ILIKE :term OR source_identity_digest ILIKE :term OR correlation_id ILIKE :term OR adapter_id ILIKE :term OR outcome ILIKE :term OR reason ILIKE :term",
        term: term,
      )
    end

    def serialize_mapping(record)
      {
        id: record.id,
        connection_id: record.connection_id,
        source_url: record.canonical_source_url,
        source_digest: record.source_identity_digest,
        state: record.state,
        topic_id: record.topic_id,
        actor: actor(record),
        lane: record.lane,
        effective_visibility: record.effective_visibility,
        created_at: record.created_at,
        updated_at: record.updated_at,
      }
    end

    def serialize_audit(record)
      {
        id: record.id,
        correlation_id: record.correlation_id,
        connection_id: record.connection_id,
        adapter_id: record.adapter_id,
        source_digest: record.source_identity_digest,
        topic_id: record.topic_id,
        actor: actor(record),
        outcome: record.outcome,
        reason: record.reason,
        created_at: record.created_at,
      }
    end

    def actor(record)
      return unless record.effective_actor

      { id: record.effective_actor.id, username: record.effective_actor.username }
    end
  end
end
