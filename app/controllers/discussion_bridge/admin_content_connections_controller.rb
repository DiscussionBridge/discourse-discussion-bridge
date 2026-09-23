# frozen_string_literal: true

module DiscussionBridge
  class AdminContentConnectionsController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def index
      connections = DiscussionBridgeContentConnection.order(:name, :id)
      render json: {
        content_connections: connections.map { |connection| serialize(connection) },
        platforms: DiscussionBridgeContentConnection::PLATFORMS,
        directions: DiscussionBridgeContentConnection::DIRECTIONS,
        categories: Category.order(:name, :id).pluck(:id, :name).map do |id, name|
          { id: id, id_string: id.to_s, name: name }
        end,
        publication_categories: publication_categories,
        publication_tags: publication_tags(connections),
        fallback_category: fallback_category,
      }
    end

    def create
      attributes = connection_params
      connection, secret = DiscussionBridgeContentConnection.issue!(attributes)
      enqueue_publication_reconciliation(connection)
      render json: { content_connection: serialize(connection), secret: secret }, status: :created
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    def update
      connection = DiscussionBridgeContentConnection.find(params[:id])
      attributes = connection_params
      requested_mapping = params.require(:content_connection)[:destination_mapping]
      connection.with_lock do
        connection.reload
        prior_mapping_revision = connection.destination_mapping_revision
        if requested_mapping
          result = DestinationMapping.call(requested_mapping, connection: connection)
          attributes[:destination_mapping] = result.mapping
          attributes[:destination_mapping_revision] = result.revision
          attributes[:destination_mapping_updated_at] = Time.zone.now
        end
        connection.update!(attributes)
        mapping_changed = requested_mapping && prior_mapping_revision != connection.destination_mapping_revision
        connection.mark_from_discourse_publications_pending! if mapping_changed
      end
      enqueue_publication_reconciliation(connection)
      render json: { content_connection: serialize(connection) }
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    def rotate_secret
      connection = DiscussionBridgeContentConnection.find(params[:id])
      render json: { content_connection: serialize(connection), secret: connection.rotate_secret! }
    end

    def request_catalog_refresh
      connection = DiscussionBridgeContentConnection.find(params[:id])
      connection.update!(platform_catalog_refresh_requested_at: Time.zone.now)
      render json: { content_connection: serialize(connection) }
    end

    def search_tags
      query = params[:q].to_s.strip
      raise Discourse::InvalidParameters.new(:q) if query.bytesize > 100
      page = Integer(params[:page].presence || 1, exception: false)
      raise Discourse::InvalidParameters.new(:page) unless page&.between?(1, 100)
      relation = Tag.order(:name, :id)
      if query.present?
        relation = relation.where(
          "name ILIKE ?",
          "%#{ActiveRecord::Base.sanitize_sql_like(query)}%",
        )
      end
      rows = relation.offset((page - 1) * 50).limit(51).pluck(:id, :name)
      render json: {
        tags: rows.first(50).map { |id, name| { id: id, name: name } },
        page: page,
        more: rows.length > 50,
      }
    end

    def publication_preview
      connection = DiscussionBridgeContentConnection.find(params[:id])
      topics = PublicationTopicScope.relation(connection).includes(:category, :tags, :first_post)
        .order(id: :asc).limit(10_001).to_a
      truncated = topics.length > 10_000
      topics = topics.first(10_000)
      grouped = Hash.new(0)
      held_samples = []
      ready = 0
      topics.each do |topic|
        destination = TopicPublicationState.for_topic(connection: connection, topic: topic).destination
        if destination["state"] == "ready"
          ready += 1
        else
          Array(destination["reasons"]).each { |reason| grouped[reason] += 1 }
          if held_samples.length < 20
            held_samples << {
              topic_id: topic.id,
              topic_url: topic.url,
              title: topic.title,
              reasons: destination["reasons"],
            }
          end
        end
      end
      render json: {
        total: topics.length,
        ready: ready,
        held: topics.length - ready,
        held_reasons: grouped.sort.to_h,
        held_samples: held_samples,
        truncated: truncated,
        mapping_state: connection.destination_mapping_current? ? "current" : "attention",
        policy_revision: TopicPublicationState.policy_revision(connection),
      }
    end

    def update_author
      connection = DiscussionBridgeContentConnection.find(params[:id])
      source_author = connection.source_authors.find(params[:author_id])
      username = params.require(:source_author).permit(:discourse_username)[:discourse_username].to_s.strip
      source_author.update!(
        discourse_user: username.present? ? author_user!(username) : nil,
      )
      render json: { source_author: serialize_source_author(source_author) }
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    private

    def enqueue_publication_reconciliation(connection)
      Jobs.enqueue(
        :discussion_bridge_reconcile_publication_connection,
        connection_id: connection.id,
      )
    end

    def connection_params
      raw = params.require(:content_connection).permit(
        :name,
        :platform,
        :author_username,
        :authorship_mode,
        :unmapped_author_policy,
        :generate_topic_toc,
        :include_source_in_published_url,
        :publication_source_path,
        :forum_publication_enabled,
        :publication_include_unlisted,
        :publication_category_mode,
        :publication_tag_mode,
        :default_category_id,
        :adapter_id,
        :adapter_version,
        :enabled,
        allowed_origins: [],
        allowed_directions: [],
        allowed_lanes: [],
        publication_category_ids: [],
        publication_excluded_category_ids: [],
        publication_tag_ids: [],
        publication_excluded_tag_ids: [],
      ).to_h.symbolize_keys
      if raw.key?(:author_username)
        username = raw.delete(:author_username).to_s.strip
        raw[:author_user_id] = username.present? ? author_user!(username).id : nil
      end
      if raw.key?(:default_category_id)
        category_id = raw[:default_category_id].to_s.strip
        raw[:default_category_id] = category_id.present? ? Integer(category_id, 10) : nil
      end
      if raw.key?(:publication_source_path)
        source_path = raw[:publication_source_path].to_s.strip.downcase
        raw[:publication_source_path] = source_path.presence
      end
      if raw.key?(:include_source_in_published_url)
        raw[:include_source_in_published_url] = ActiveModel::Type::Boolean.new.cast(
          raw[:include_source_in_published_url],
        )
        raw[:publication_source_path] = nil unless raw[:include_source_in_published_url]
      end
      %i[forum_publication_enabled publication_include_unlisted].each do |key|
        raw[key] = ActiveModel::Type::Boolean.new.cast(raw[key]) if raw.key?(key)
      end
      %i[
        publication_category_ids publication_excluded_category_ids
        publication_tag_ids publication_excluded_tag_ids
      ].each do |key|
        next unless raw.key?(key)
        raw[key] = Array(raw[key]).map { |value| Integer(value.to_s, 10) }.uniq
      end
      raw[:allowed_origins] = Array(raw[:allowed_origins]).map { |origin| CanonicalSource.origin(origin) } if raw.key?(:allowed_origins)
      raw[:allowed_directions] = Array(raw[:allowed_directions]).map(&:to_s) if raw.key?(:allowed_directions)
      raw[:allowed_lanes] = Array(raw[:allowed_lanes]).map(&:to_s) if raw.key?(:allowed_lanes)
      raw
    end

    def author_user!(username)
      user = User.find_by(username_lower: username.downcase)
      valid = user&.active? && !user.staged? && !user.suspended? && !user.silenced? &&
        user.id != Discourse::SYSTEM_USER_ID
      raise ArgumentError, "author username is unavailable" unless valid

      user
    end

    def serialize(connection)
      bindings = connection.content_bindings
      active_records = bindings.where(state: "active").distinct.count(:bridge_record_id)
      attention_records = DiscussionBridgeBridgeRecord
        .joins(:content_bindings)
        .where(
          discussion_bridge_content_bindings: { content_connection_id: connection.id },
          state: %w[attention failed migration],
        ).distinct.count
      work_counts = connection.publication_work_items.group(:state).count
      publication_attention = work_counts.slice(*DiscussionBridgePublicationWorkItem::ATTENTION_STATES).values.sum
      {
        id: connection.id,
        public_id: connection.public_id,
        name: connection.name,
        platform: connection.platform,
        author_username: connection.effective_author&.username,
        author_override: connection.author_user_id.present?,
        authorship_mode: connection.authorship_mode,
        unmapped_author_policy: connection.unmapped_author_policy,
        generate_topic_toc: connection.generate_topic_toc,
        include_source_in_published_url: connection.include_source_in_published_url,
        publication_source_path: connection.publication_source_path,
        forum_publication_enabled: connection.forum_publication_enabled,
        publication_include_unlisted: connection.publication_include_unlisted,
        publication_category_mode: connection.publication_category_mode,
        publication_tag_mode: connection.publication_tag_mode,
        publication_category_ids: connection.publication_category_ids,
        publication_excluded_category_ids: connection.publication_excluded_category_ids,
        publication_tag_ids: connection.publication_tag_ids,
        publication_excluded_tag_ids: connection.publication_excluded_tag_ids,
        platform_catalog: connection.platform_catalog,
        platform_catalog_revision: connection.platform_catalog_revision,
        platform_catalog_display_revision: connection.platform_catalog_display_revision,
        platform_catalog_adapter_id: connection.platform_catalog_adapter_id,
        platform_catalog_adapter_version: connection.platform_catalog_adapter_version,
        platform_catalog_observed_at: connection.platform_catalog_observed_at,
        platform_catalog_refresh_requested_at: connection.platform_catalog_refresh_requested_at,
        destination_mapping: connection.destination_mapping,
        destination_mapping_revision: connection.destination_mapping_revision,
        destination_mapping_updated_at: connection.destination_mapping_updated_at,
        destination_mapping_state: connection.destination_mapping_current? ? "current" : "attention",
        default_category_id: connection.default_category_id,
        category_route: category_route(connection),
        source_authors: connection.source_authors.order(:display_name, :source_author_id).map do |source_author|
          serialize_source_author(source_author)
        end,
        source_author_count: connection.source_authors.count,
        unmapped_source_author_count: connection.source_authors.where(discourse_user_id: nil).count,
        enabled: connection.enabled,
        allowed_origins: connection.allowed_origins,
        origin_readiness: EmbeddableOriginStatus.for_connection(connection),
        allowed_directions: connection.allowed_directions,
        allowed_lanes: connection.allowed_lanes,
        adapter_id: connection.adapter_id,
        adapter_version: connection.adapter_version,
        last_seen_at: connection.last_seen_at,
        bridge_record_count: active_records,
        attention_count: attention_records + publication_attention,
        publication_work: DiscussionBridgePublicationWorkItem::STATES.index_with do |state|
          work_counts.fetch(state, 0)
        end,
        health: if !connection.enabled || attention_records.positive? || publication_attention.positive?
                  "attention"
                elsif connection.last_seen_at.nil?
                  "setup"
                else
                  "healthy"
                end,
      }
    end

    def serialize_source_author(source_author)
      {
        id: source_author.id,
        source_author_id: source_author.source_author_id,
        display_name: source_author.display_name,
        profile_url: source_author.profile_url,
        discourse_username: source_author.discourse_user&.username,
        mapped: source_author.discourse_user_id.present?,
        last_seen_at: source_author.last_seen_at,
      }
    end

    def fallback_category
      category = Category.find_by(id: SiteSetting.discussion_bridge_effective_category_id)
      { id: category&.id, name: category&.name }
    end

    def publication_categories
      categories = Category.where(read_restricted: false).order(:name, :id).to_a
      by_id = categories.index_by(&:id)
      categories.map do |category|
        names = []
        cursor = category
        visited = {}
        while cursor && !visited[cursor.id]
          visited[cursor.id] = true
          names.unshift(cursor.name)
          cursor = by_id[cursor.parent_category_id]
        end
        { id: category.id, name: category.name, slug: category.slug, path: names.join(" / ") }
      end.sort_by { |category| [category[:path].downcase, category[:id]] }
    end

    def publication_tags(connections)
      selected = connections.flat_map do |connection|
        Array(connection.publication_tag_ids) + Array(connection.publication_excluded_tag_ids) +
          Array(connection.destination_mapping["tag_mappings"]).map { |item| item["source_tag_id"] }
      end.uniq
      initial = Tag.order(:name, :id).limit(100).pluck(:id)
      Tag.where(id: (selected + initial).uniq).order(:name, :id)
        .pluck(:id, :name).map { |id, name| { id: id, name: name } }
    end

    def category_route(connection)
      category = Category.find_by(id: connection.default_category_id) ||
        Category.find_by(id: SiteSetting.discussion_bridge_effective_category_id)
      {
        category_id: category&.id,
        category_name: category&.name,
        source: connection.default_category_id.present? ? "connection" : "forum_fallback",
      }
    end

    def errors_for(error)
      error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
    end
  end
end
