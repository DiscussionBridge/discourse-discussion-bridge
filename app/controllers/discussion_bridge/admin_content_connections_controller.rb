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

    private

    def connection_params
      raw = params.require(:content_connection).permit(
        :name,
        :platform,
        :author_username,
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
        enabled: connection.enabled,
        allowed_origins: connection.allowed_origins,
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

    def errors_for(error)
      error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
    end
  end
end
