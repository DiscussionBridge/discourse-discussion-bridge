# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class AdminBridgeRecordsController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    MAX_PAGE = 10_000
    PER_PAGE = 25

    def index
      page = Integer(params[:page].presence || 1, exception: false)
      raise Discourse::InvalidParameters.new(:page) unless page&.between?(1, MAX_PAGE)

      scope = DiscussionBridgeBridgeRecord.includes(:topic, content_bindings: :content_connection)
      scope = scope.where(direction: params[:direction]) if DiscussionBridgeBridgeRecord::DIRECTIONS.include?(params[:direction])
      scope = scope.where(state: params[:state]) if DiscussionBridgeBridgeRecord::STATES.include?(params[:state])
      if params[:connection_id].present?
        scope = scope.joins(:content_bindings).where(
          discussion_bridge_content_bindings: { content_connection_id: params[:connection_id] },
        ).distinct
      end
      if params[:query].present?
        term = params[:query].to_s.strip
        raise Discourse::InvalidParameters.new(:query) if term.bytesize > 200
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
        scope = scope.where("resource_id ILIKE :term OR title ILIKE :term", term: pattern)
      end

      total = scope.count
      records = scope.order(updated_at: :desc, id: :desc).offset((page - 1) * PER_PAGE).limit(PER_PAGE)
      render json: {
        bridge_records: records.map { |record| serialize(record) },
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
        raise ArgumentError, "migration already prepared" if record.content_bindings.exists?(role: role, state: "prepared")
        identity_digest = Digest::SHA256.hexdigest("#{connection.public_id}\n#{external_id}")
        canonical_url_digest = Digest::SHA256.hexdigest("#{connection.public_id}\n#{canonical.source_url}")
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
      DiscussionBridgeBridgeRecord.transaction do
        record.lock!
        prepared = record.content_bindings.lock.find_by!(id: params[:binding_id], state: "prepared")
        expected_role = record.direction == "to_discourse" ? "source" : "presentation"
        raise ArgumentError, "prepared binding role does not match record direction" unless prepared.role == expected_role

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

    private

    def serialize(record, detailed: false)
      bindings = record.content_bindings.sort_by { |binding| [binding.role, binding.created_at, binding.id] }
      active = bindings.select { |binding| binding.state == "active" }
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
        updated_at: record.updated_at,
      }
      payload[:bindings] = bindings.map { |binding| binding_payload(binding) } if detailed
      payload
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
  end
end
