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
        fallback_category: fallback_category,
      }
    end

    def create
      attributes = connection_params
      connection, secret = DiscussionBridgeContentConnection.issue!(attributes)
      render json: { content_connection: serialize(connection), secret: secret }, status: :created
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    def update
      connection = DiscussionBridgeContentConnection.find(params[:id])
      connection.update!(connection_params)
      render json: { content_connection: serialize(connection) }
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    def rotate_secret
      connection = DiscussionBridgeContentConnection.find(params[:id])
      render json: { content_connection: serialize(connection), secret: connection.rotate_secret! }
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
        :default_category_id,
        :adapter_id,
        :adapter_version,
        :enabled,
        allowed_origins: [],
        allowed_directions: [],
        allowed_lanes: [],
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
        attention_count: attention_records,
        health: if !connection.enabled || attention_records.positive?
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
