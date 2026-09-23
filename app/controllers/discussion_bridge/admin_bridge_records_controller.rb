# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class AdminBridgeRecordsController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    MAX_PAGE = 10_000
    PER_PAGE = 25
    SORT_COLUMNS = %w[updated title connection direction topic publication status].freeze
    SORT_ORDERS = %w[asc desc].freeze
    RECORD_TABLE = DiscussionBridgeBridgeRecord.table_name.freeze
    WORK_TABLE = DiscussionBridgePublicationWorkItem.table_name.freeze
    BINDING_TABLE = DiscussionBridgeContentBinding.table_name.freeze
    CONNECTION_TABLE = DiscussionBridgeContentConnection.table_name.freeze
    ACTIVE_CONNECTION_NAME_SQL = <<~SQL.squish.freeze
      (SELECT MIN(connection.name)
       FROM #{BINDING_TABLE} binding
       INNER JOIN #{CONNECTION_TABLE} connection
         ON connection.id = binding.content_connection_id
       WHERE binding.bridge_record_id = #{RECORD_TABLE}.id
         AND binding.state = 'active')
    SQL
    WORK_STATE_SQL = <<~SQL.squish.freeze
      (SELECT work.state
       FROM #{WORK_TABLE} work
       INNER JOIN #{BINDING_TABLE} binding
         ON binding.bridge_record_id = #{RECORD_TABLE}.id
        AND binding.content_connection_id = work.content_connection_id
        AND binding.state = 'active'
       WHERE work.bridge_record_id = #{RECORD_TABLE}.id
       ORDER BY work.id DESC
       LIMIT 1)
    SQL
    WORK_ACTION_SQL = <<~SQL.squish.freeze
      (SELECT work.action
       FROM #{WORK_TABLE} work
       INNER JOIN #{BINDING_TABLE} binding
         ON binding.bridge_record_id = #{RECORD_TABLE}.id
        AND binding.content_connection_id = work.content_connection_id
        AND binding.state = 'active'
       WHERE work.bridge_record_id = #{RECORD_TABLE}.id
       ORDER BY work.id DESC
       LIMIT 1)
    SQL
    PUBLICATION_STATE_SQL = <<~SQL.squish.freeze
      CASE
        WHEN #{RECORD_TABLE}.direction = 'to_discourse' AND #{RECORD_TABLE}.topic_id IS NOT NULL
          THEN 'in_discourse'
        WHEN #{WORK_STATE_SQL} IN ('attention', 'failed')
          OR #{RECORD_TABLE}.destination_state IN ('attention', 'failed')
          THEN 'needs_attention'
        WHEN #{WORK_STATE_SQL} IN ('queued', 'claimed', 'retrying')
          AND #{WORK_ACTION_SQL} = 'unpublish'
          THEN 'pending_removal'
        WHEN #{WORK_STATE_SQL} IN ('queued', 'claimed', 'retrying')
          THEN 'pending_publication'
        WHEN #{WORK_STATE_SQL} = 'unpublished' OR #{RECORD_TABLE}.destination_state = 'held'
          THEN 'not_published'
        WHEN #{WORK_STATE_SQL} = 'current' OR #{RECORD_TABLE}.destination_state = 'healthy'
          THEN 'published'
        ELSE 'not_published'
      END
    SQL
    OPERATIONAL_STATE_SQL = <<~SQL.squish.freeze
      COALESCE(#{WORK_STATE_SQL}, #{RECORD_TABLE}.destination_state, #{RECORD_TABLE}.state)
    SQL
    SORT_SQL = {
      "updated" => "#{RECORD_TABLE}.updated_at",
      "title" => "LOWER(#{RECORD_TABLE}.title)",
      "connection" => ACTIVE_CONNECTION_NAME_SQL,
      "direction" => "#{RECORD_TABLE}.direction",
      "topic" => "#{RECORD_TABLE}.topic_id",
      "publication" => PUBLICATION_STATE_SQL,
      "status" => OPERATIONAL_STATE_SQL,
    }.freeze

    def index
      page = Integer(params[:page].presence || 1, exception: false)
      raise Discourse::InvalidParameters.new(:page) unless page&.between?(1, MAX_PAGE)
      sort = params[:sort].presence || "updated"
      order = params[:order].presence || "desc"
      raise Discourse::InvalidParameters.new(:sort) if SORT_COLUMNS.exclude?(sort)
      raise Discourse::InvalidParameters.new(:order) if SORT_ORDERS.exclude?(order)

      scope = DiscussionBridgeBridgeRecord.includes(
        :topic,
        :publication_work_items,
        content_bindings: :content_connection,
      )
      scope = scope.where(direction: params[:direction]) if DiscussionBridgeBridgeRecord::DIRECTIONS.include?(params[:direction])
      scope = scope.where(state: params[:state]) if DiscussionBridgeBridgeRecord::STATES.include?(params[:state])
      if params[:connection_id].present?
        scope = scope.where(
          id: DiscussionBridgeContentBinding
            .where(content_connection_id: params[:connection_id])
            .select(:bridge_record_id),
        )
      end
      if params[:query].present?
        term = params[:query].to_s.strip
        raise Discourse::InvalidParameters.new(:query) if term.bytesize > 200
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
        scope = scope.where("resource_id ILIKE :term OR title ILIKE :term", term: pattern)
      end

      total = scope.count
      direction = order.upcase
      records = scope
        .order(Arel.sql("#{SORT_SQL.fetch(sort)} #{direction} NULLS LAST, #{RECORD_TABLE}.id #{direction}"))
        .offset((page - 1) * PER_PAGE)
        .limit(PER_PAGE)
      render json: {
        bridge_records: records.map { |record| serialize(record) },
        filters: {
          query: params[:query].to_s,
          direction: params[:direction].to_s,
          state: params[:state].to_s,
          connection_id: params[:connection_id].to_s,
        },
        sorting: { sort: sort, order: order },
        pagination: {
          page: page,
          per_page: PER_PAGE,
          total: total,
          pages: [(total.to_f / PER_PAGE).ceil, 1].max,
        },
      }
    end

    def show
      render json: { bridge_record: serialize(DiscussionBridgeBridgeRecord.find(params[:id]), detailed: true) }
    end

    def create
      input = params.require(:bridge_record)
      result = FromDiscourseRecordCreator.call(
        user: current_user,
        connection_id: input.fetch(:content_connection_id),
        topic_id: input.fetch(:topic_id),
        external_id: input.fetch(:external_id),
        canonical_url: input.fetch(:canonical_url),
        lane: input[:lane],
      )
      render json: {
        bridge_record: serialize(result.record, detailed: true),
        outcome: result.outcome,
      }, status: result.outcome == "created" ? :created : :ok
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    def prepare_migration
      raise ArgumentError, "presentation migration requires a verified URL cutover" if
        DiscussionBridgeBridgeRecord.find(params[:id]).direction == "from_discourse"
      connection_id = params.require(:migration).fetch(:content_connection_id)
      external_id = params.require(:migration).fetch(:external_id)
      raise ArgumentError, "invalid external_id" unless DiscussionBridgeContentBinding.valid_external_id?(external_id)

      binding = nil
      record = nil
      DiscussionBridgeBridgeRecord.transaction do
        record = DiscussionBridgeBridgeRecord.lock.find(params[:id])
        connection = DiscussionBridgeContentConnection.lock.find(connection_id)
        raise ArgumentError, "target connection is unavailable" unless connection.enabled &&
          connection.allows_direction?(record.direction)
        raise ArgumentError, "lane is outside target connection scope" unless connection.allows_lane?(record.lane)
        canonical = CanonicalSource.call(
          connection_id: connection.public_id,
          source_url: params.require(:migration).fetch(:canonical_url),
        )
        raise ArgumentError, "origin is outside target connection scope" unless connection.allows_origin?(canonical.source_url)
        role = record.direction == "to_discourse" ? "source" : "presentation"
        raise ArgumentError, "presentation migration requires a verified URL cutover" if role == "presentation"
        raise ArgumentError, "migration already prepared" if record.content_bindings.exists?(role: role, state: "prepared")
        identity_digest = Digest::SHA256.hexdigest("#{connection.public_id}\n#{external_id}")
        canonical_url_digest = Digest::SHA256.hexdigest("#{connection.public_id}\n#{canonical.source_url}")
        raise ArgumentError, "target URL is reserved by publication history" if
          DiscussionBridgePresentationUrlHistory.where(old_canonical_url_digest: canonical_url_digest).exists? ||
            DiscussionBridgeSourceUrlHistory.where(old_canonical_url_digest: canonical_url_digest).exists?
        matches = DiscussionBridgeContentBinding.lock.where(
          "identity_digest = :identity OR canonical_url_digest = :url",
          identity: identity_digest,
          url: canonical_url_digest,
        ).to_a
        if matches.any?
          binding = matches.one? && matches.first
          reusable = binding && binding.bridge_record_id == record.id && binding.role == role &&
            binding.state == "historical" && binding.content_connection_id == connection.id &&
            binding.external_id == external_id && binding.canonical_url == canonical.source_url &&
            binding.identity_digest == identity_digest && binding.canonical_url_digest == canonical_url_digest
          raise ArgumentError, "target binding conflicts with existing history" unless reusable

          binding.update!(state: "prepared", activated_at: nil, retired_at: nil)
        else
          binding = DiscussionBridgeContentBinding.create!(
            bridge_record: record,
            content_connection: connection,
            role: role,
            state: "prepared",
            external_id: external_id,
            canonical_url: canonical.source_url,
            identity_digest: identity_digest,
            canonical_url_digest: canonical_url_digest,
          )
        end
        record.update!(state: "migration")
      end
      render json: { bridge_record: serialize(record.reload, detailed: true), prepared_binding_id: binding.id }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    def apply_migration
      record = DiscussionBridgeBridgeRecord.find(params[:id])
      raise ArgumentError, "presentation migration requires a verified URL cutover" if
        record.direction == "from_discourse"
      DiscussionBridgeBridgeRecord.transaction do
        record.lock!
        prepared = record.content_bindings.lock.find_by!(id: params[:binding_id], state: "prepared")
        expected_role = record.direction == "to_discourse" ? "source" : "presentation"
        raise ArgumentError, "prepared binding role does not match record direction" unless prepared.role == expected_role
        raise ArgumentError, "presentation migration requires a verified URL cutover" if expected_role == "presentation"

        connection = DiscussionBridgeContentConnection.lock.find(prepared.content_connection_id)
        raise ArgumentError, "target connection is unavailable" unless connection.enabled &&
          connection.allows_direction?(record.direction)
        raise ArgumentError, "lane is outside target connection scope" unless connection.allows_lane?(record.lane)
        raise ArgumentError, "origin is outside target connection scope" unless connection.allows_origin?(prepared.canonical_url)

        active = record.content_bindings.lock.where(state: "active").to_a
        raise ArgumentError, "record has an invalid active binding set" unless
          active.length <= 1 && active.all? { |binding| binding.role == expected_role }
        current = active.first
        current&.update!(state: "historical", retired_at: Time.zone.now)
        prepared.update!(state: "active", activated_at: Time.zone.now)
        record.update!(state: "healthy")
      end
      render json: { bridge_record: serialize(record.reload, detailed: true) }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    def migrate_source_url
      input = params.require(:migration)
      record = DiscussionBridgeBridgeRecord.find(params[:id])
      result = SourceUrlMigrator.call(
        user: current_user,
        resource_id: record.resource_id,
        old_url: input.fetch(:old_url),
        new_url: input.fetch(:new_url),
        external_id: input.fetch(:external_id),
        native_identity_confirmed: input[:native_identity_confirmed] == true ||
          input[:native_identity_confirmed] == "true",
      )
      render json: {
        bridge_record: serialize(result.record, detailed: true),
        outcome: result.outcome,
        redirect_status: result.redirect_status,
      }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique,
           ActiveRecord::RecordNotFound, ArgumentError => error
      errors = error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
      render json: { errors: errors }, status: :unprocessable_entity
    end

    private

    def serialize(record, detailed: false)
      bindings = record.content_bindings.sort_by { |binding| [binding.role, binding.created_at, binding.id] }
      active = bindings.select { |binding| binding.state == "active" }
      active_connection_id = active.first&.content_connection_id
      work = record.publication_work_items.find do |item|
        item.content_connection_id == active_connection_id
      end
      payload = {
        id: record.id,
        resource_id: record.resource_id,
        title: record.title,
        direction: record.direction,
        state: record.state,
        topic_id: record.topic_id,
        topic_url: record.topic&.url,
        reply_count: record.topic ? [record.topic.posts_count.to_i - 1, 0].max : 0,
        lane: record.lane,
        source_authors: record.source_authors,
        primary_source_author_id: record.primary_source_author_id,
        connection_names: active.map { |binding| binding.content_connection.name },
        active_binding: active.first && binding_payload(active.first),
        publication_work: work && publication_work_payload(work),
        publication_state: publication_state(record, work),
        operational_state: work&.state || record.destination_state || record.state,
        updated_at: record.updated_at,
      }
      payload[:bindings] = bindings.map { |binding| binding_payload(binding) } if detailed
      payload
    end

    def publication_state(record, work)
      return "in_discourse" if record.direction == "to_discourse" && record.topic_id
      return "needs_attention" if DiscussionBridgePublicationWorkItem::ATTENTION_STATES.include?(work&.state) ||
        %w[attention failed].include?(record.destination_state)
      if DiscussionBridgePublicationWorkItem::ACTIVE_STATES.include?(work&.state)
        return work.action == "unpublish" ? "pending_removal" : "pending_publication"
      end
      return "not_published" if work&.state == "unpublished" || record.destination_state == "held"
      return "published" if work&.state == "current" || record.destination_state == "healthy"

      "not_published"
    end

    def binding_payload(binding)
      {
        id: binding.id,
        role: binding.role,
        state: binding.state,
        external_id: binding.external_id,
        canonical_url: binding.canonical_url,
        connection: {
          id: binding.content_connection.id,
          public_id: binding.content_connection.public_id,
          name: binding.content_connection.name,
          platform: binding.content_connection.platform,
        },
        activated_at: binding.activated_at,
        retired_at: binding.retired_at,
      }
    end

    def publication_work_payload(item)
      {
        action: item.action,
        state: item.state,
        reason: item.reason,
        source_revision: item.source_revision,
        publication_revision: item.publication_revision,
        attempt_count: item.attempt_count,
        available_at: item.available_at,
        claimed_at: item.claimed_at,
        lease_expires_at: item.lease_expires_at,
        completed_at: item.completed_at,
        last_error_code: item.last_error_code,
        last_error_detail: item.last_error_detail,
      }
    end
  end
end
