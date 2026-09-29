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
      connection.update!(connection_params(existing: connection))
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
      raise ArgumentError, "connection does not use a platform catalog" unless
        connection.enabled && connection.catalog_required &&
          connection.allows_direction?("from_discourse")

      connection.update!(platform_catalog_refresh_requested_at: Time.zone.now)
      render json: { content_connection: serialize(connection) }
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    def publication_preview
      connection = DiscussionBridgeContentConnection.find(params[:id])
      raise ArgumentError, "connection does not permit From Discourse" unless
        connection.enabled && connection.allows_direction?("from_discourse")

      scope = DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(
          direction: "from_discourse",
          discussion_bridge_content_bindings: {
            content_connection_id: connection.id,
            role: "presentation",
            state: "active",
          },
        ).distinct.order(:id)
      total = scope.count
      records = scope.includes(:topic, :publication_works).limit(101).to_a
      render json: {
        content_connection_id: connection.id,
        total: total,
        truncated: total > 100,
        items: records.first(100).map { |record| preview_item(connection, record) },
        attention: connection.publication_works.where(state: "operator_attention").count,
        catalog: catalog_payload(connection),
      }
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
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

    def connection_params(existing: nil)
      raw = params.require(:content_connection).permit(
        :name,
        :platform,
        :author_username,
        :authorship_mode,
        :unmapped_author_policy,
        :generate_topic_toc,
        :default_category_id,
        :adapter_id,
        :adapter_version,
        :enabled,
        :network_enabled,
        :network_peer_forum_id,
        :network_relationship,
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
      raw[:allowed_origins] = Array(raw[:allowed_origins]).map { |origin| CanonicalSource.origin(origin) } if raw.key?(:allowed_origins)
      raw[:allowed_directions] = Array(raw[:allowed_directions]).map(&:to_s) if raw.key?(:allowed_directions)
      raw[:allowed_lanes] = Array(raw[:allowed_lanes]).map(&:to_s) if raw.key?(:allowed_lanes)
      configure_discourse_network!(raw, existing: existing) if raw.key?(:network_enabled)
      configure_publication_policy!(raw, existing: existing) if
        !ActiveModel::Type::Boolean.new.cast(raw.fetch(:network_enabled, existing&.network_enabled)) &&
          (existing.nil? || raw.key?(:platform) || raw.key?(:allowed_directions) || raw.key?(:network_enabled))
      raw
    end

    def configure_publication_policy!(raw, existing:)
      platform = raw[:platform] || existing&.platform
      directions = raw[:allowed_directions] || existing&.allowed_directions || []
      if Array(directions).exclude?("from_discourse")
        raw[:destination_policies] = []
        raw[:policy_revision] = nil
        raw[:catalog_required] = false
        return
      end

      profile = {
        "astro" => "astro",
        "discourse" => "discourse_as_publisher",
        "ghost" => "ghost",
        "hugo" => "hugo",
        "statamic" => "statamic_db",
        "wordpress" => "wordpress",
      }.fetch(platform) { raise ArgumentError, "platform cannot receive From Discourse publications" }
      catalog_revision = "catalog:#{profile}:initial"
      policy = {
        "destination_policy_id" => "destination:#{profile}:default",
        "profile" => profile,
        "presentation_mode" => "interactive",
        "container_mapping" => {
          "source" => "discourse:topics",
          "destination" => "#{profile}:default",
        },
        "taxonomy_mapping" => { "mode" => "source_attribution" },
        "author_mapping" => { "mode" => "source_attribution" },
        "native_limit_policy" => {
          "maximum_bytes" => BridgeRecordRequest::MAX_CONTENT_HTML_BYTES,
          "overflow_behavior" => "excerpt_with_read_more",
        },
        "catalog_revision" => catalog_revision,
      }
      raw[:destination_policies] = [policy]
      raw[:policy_revision] = "policy:admin:#{Digest::SHA256.hexdigest(JSON.generate(policy))[0, 32]}"
      raw[:catalog_required] = profile != "discourse_as_publisher"
    end

    def configure_discourse_network!(raw, existing:)
      enabled = ActiveModel::Type::Boolean.new.cast(raw[:network_enabled])
      raw[:network_enabled] = enabled
      unless enabled
        raw[:network_peer_forum_id] = nil
        raw[:network_relationship] = nil
        return
      end

      raise ArgumentError, "network identity is not enabled" unless
        DiscussionBridgeForumIdentity.current&.ready?
      platform = raw[:platform] || existing&.platform
      raise ArgumentError, "network connections require the Discourse platform" unless platform == "discourse"

      peer_forum_id = raw[:network_peer_forum_id] || existing&.network_peer_forum_id
      relationship = raw[:network_relationship] || existing&.network_relationship
      policy = DiscourseNetworkProtocol.destination_policy(
        peer_forum_id: peer_forum_id,
        relationship: relationship,
      )
      raw[:destination_policies] = [policy]
      raw[:policy_revision] = DiscourseNetworkProtocol.policy_revision(
        peer_forum_id: peer_forum_id,
        relationship: relationship,
      )
      raw[:catalog_required] = false
    rescue AdapterRequestBoundary::Error
      raise ArgumentError, "network peer configuration is invalid"
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
        default_category_id: connection.default_category_id,
        category_route: category_route(connection),
        source_authors: connection.source_authors.order(:display_name, :source_author_id).map do |source_author|
          serialize_source_author(source_author)
        end,
        source_author_count: connection.source_authors.count,
        unmapped_source_author_count: connection.source_authors.where(discourse_user_id: nil).count,
        enabled: connection.enabled,
        allowed_origins: connection.allowed_origins,
        allowed_directions: connection.allowed_directions,
        allowed_lanes: connection.allowed_lanes,
        adapter_id: connection.adapter_id,
        adapter_version: connection.adapter_version,
        network_enabled: connection.network_enabled,
        network_peer_forum_id: connection.network_peer_forum_id,
        network_relationship: connection.network_relationship,
        policy_revision: connection.policy_revision,
        destination_policies: connection.destination_policies,
        catalog_required: connection.catalog_required,
        last_seen_at: connection.last_seen_at,
        bridge_record_count: active_records,
        attention_count: attention_records,
        publication_work: PublicationWorkProtocol::STATES.index_with do |state|
          connection.publication_works.where(state: state).count
        end,
        catalog: catalog_payload(connection),
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

    def catalog_payload(connection)
      catalogs = connection.platform_catalogs.where(current: true).order(:platform_profile)
      {
        required: connection.catalog_required,
        refresh_requested_at: connection.platform_catalog_refresh_requested_at,
        current: catalogs.map do |catalog|
          {
            platform_profile: catalog.platform_profile,
            catalog_revision: catalog.catalog_revision,
            updated_at: catalog.updated_at,
          }
        end,
      }
    end

    def preview_item(connection, record)
      work = record.publication_works.where(content_connection_id: connection.id)
        .order(id: :desc).first
      override = DiscussionBridgePublicationOverride.find_by(
        content_connection_id: connection.id,
        topic_id: record.topic_id,
      )
      {
        resource_id: record.resource_id,
        topic_id: record.topic_id,
        topic_url: record.topic&.url,
        title: record.topic&.title || record.title,
        record_state: record.state,
        decision: override&.decision || "inherit",
        work: work && {
          work_id: work.work_id,
          action: work.action,
          state: work.state,
          failure_code: work.failure_code,
        },
      }
    end
  end
end
