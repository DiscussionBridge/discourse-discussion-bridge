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
      DiscussionBridgeContentConnection.transaction do
        connection.lock!
        attributes = connection_params(existing: connection)
        previous_authority = {
          enabled: connection.enabled,
          allowed_directions: Array(connection.allowed_directions),
          destination_policies: Array(connection.destination_policies).map(&:deep_dup),
          policy_revision: connection.policy_revision,
        }
        connection.update!(attributes)
        SourceRevocationRegistry.reconcile_policy_removal!(
          connection: connection,
          previous_authority: previous_authority,
        )
      end
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
        :preserve_existing_policy_fields,
        :replace_existing_policy_fields,
        allowed_origins: [],
        allowed_directions: [],
        allowed_lanes: [],
        publication_policy: [
          :destination_policy_id,
          :profile,
          :presentation_mode,
          :catalog_revision,
          { container_mapping: %i[source destination] },
          { taxonomy_mapping: [:mode, { items: %i[source destination] }] },
          { author_mapping: [:mode, :destination_id, { items: %i[source destination] }] },
          { native_limit_policy: %i[maximum_bytes overflow_behavior] },
        ],
      ).to_h.symbolize_keys
      ensure_platform_immutable!(raw, existing)
      publication_policy = raw.delete(:publication_policy)
      preserve_existing_policy_fields =
        ActiveModel::Type::Boolean.new.cast(raw.delete(:preserve_existing_policy_fields))
      replace_existing_policy_fields =
        ActiveModel::Type::Boolean.new.cast(raw.delete(:replace_existing_policy_fields))
      if preserve_existing_policy_fields && replace_existing_policy_fields
        raise ArgumentError, "publication policy fields cannot be both preserved and replaced"
      end
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
      configure_publication_policy!(raw, existing: existing) if publication_policy.nil? &&
        !ActiveModel::Type::Boolean.new.cast(raw.fetch(:network_enabled, existing&.network_enabled)) &&
          publication_authority_changed?(raw, existing)
      if publication_policy
        configure_explicit_publication_policy!(
          raw,
          existing,
          publication_policy,
          preserve_existing_policy_fields: preserve_existing_policy_fields,
          replace_existing_policy_fields: replace_existing_policy_fields,
        )
      end
      raw
    end

    def publication_authority_changed?(raw, existing)
      return true unless existing
      return true if raw.key?(:network_enabled) && existing.network_enabled

      raw.key?(:allowed_directions) &&
        Array(raw[:allowed_directions]).map(&:to_s).sort != Array(existing.allowed_directions).map(&:to_s).sort
    end

    def ensure_platform_immutable!(raw, existing)
      return unless existing && raw.key?(:platform) && raw[:platform] != existing.platform

      raise ArgumentError, "connection platform cannot be changed after creation"
    end

    def configure_publication_policy!(raw, existing:)
      platform = raw[:platform] || existing&.platform
      directions = raw[:allowed_directions] || existing&.allowed_directions || []
      unless Array(directions).intersect?(%w[to_discourse from_discourse])
        raw[:destination_policies] = []
        raw[:policy_revision] = nil
        raw[:catalog_required] = false
        return
      end

      profile = if Array(directions).include?("from_discourse")
        {
          "astro" => "astro",
          "discourse" => "discourse_as_publisher",
          "ghost" => "ghost",
          "hugo" => "hugo",
          "statamic" => "statamic_db",
          "wordpress" => "wordpress",
        }.fetch(platform) { raise ArgumentError, "platform cannot receive From Discourse publications" }
      else
        "discourse_as_publisher"
      end
      catalog_revision = "catalog:#{profile}:initial"
      pending_catalog_mapping = profile != "discourse_as_publisher"
      policy = {
        "destination_policy_id" => "destination:#{profile}:#{pending_catalog_mapping ? "pending" : "default"}",
        "profile" => profile,
        "presentation_mode" => "interactive",
        "container_mapping" => {
          "source" => "discourse:topics",
          "destination" => pending_catalog_mapping ?
            "discussion-bridge:pending-catalog-mapping" : "#{profile}:default",
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

    def configure_explicit_publication_policy!(
      raw,
      existing,
      supplied,
      preserve_existing_policy_fields: false,
      replace_existing_policy_fields: false
    )
      raise ArgumentError, "publication policy can only update an existing connection" unless existing
      raise ArgumentError, "network policy is receiver-owned" if
        ActiveModel::Type::Boolean.new.cast(raw.fetch(:network_enabled, existing.network_enabled))

      policy = supplied.deep_stringify_keys
      existing_policy = Array(existing.destination_policies).map(&:deep_stringify_keys).find do |candidate|
        candidate["profile"] == policy["profile"] &&
          candidate["destination_policy_id"] == policy["destination_policy_id"] &&
          candidate.dig("container_mapping", "destination") !=
            "discussion-bridge:pending-catalog-mapping"
      end
      preserve_existing = preserve_existing_policy_fields ||
        (generic_attribution_mappings?(policy) && !replace_existing_policy_fields)
      if existing_policy && preserve_existing
        policy["destination_policy_id"] = existing_policy.fetch("destination_policy_id")
        policy["container_mapping"]["source"] = existing_policy.fetch("container_mapping").fetch("source")
        policy["taxonomy_mapping"] = existing_policy.fetch("taxonomy_mapping")
        policy["author_mapping"] = existing_policy.fetch("author_mapping")
      end
      native_limit_policy = policy.fetch("native_limit_policy")
      maximum_bytes = native_limit_policy.fetch("maximum_bytes")
      native_limit_policy["maximum_bytes"] =
        maximum_bytes.is_a?(Integer) ? maximum_bytes : Integer(maximum_bytes, 10)
      platform = raw[:platform] || existing.platform
      directions = raw[:allowed_directions] || existing.allowed_directions
      allowed_profiles = publication_profiles(platform, directions)
      raise ArgumentError, "publication policy profile is outside the connection scope" if
        allowed_profiles.exclude?(policy["profile"])
      raise ArgumentError, "publication policy is invalid" unless
        ConnectionCapability.valid_destination_policies?([policy])

      catalog = existing.platform_catalogs.find_by(
        platform_profile: policy.fetch("profile"),
        catalog_revision: policy.fetch("catalog_revision"),
        current: true,
      )
      raise ArgumentError, "publication policy must use the current platform catalog" unless catalog

      require_available_catalog_item!(catalog, "containers", policy.dig("container_mapping", "destination"))
      require_available_catalog_item!(catalog, "presentation_modes", policy.fetch("presentation_mode"))
      require_available_native_limit!(catalog, policy.fetch("native_limit_policy"))
      referenced_mapping_ids(policy.fetch("taxonomy_mapping")).each do |identifier|
        require_available_catalog_item!(catalog, "terms", identifier)
      end
      referenced_mapping_ids(policy.fetch("author_mapping")).each do |identifier|
        require_available_catalog_item!(catalog, "authors", identifier)
      end

      raw[:destination_policies] = [policy]
      raw[:policy_revision] = "policy:admin:#{Digest::SHA256.hexdigest(JSON.generate(policy))[0, 32]}"
      raw[:catalog_required] = true
    end

    def generic_attribution_mappings?(policy)
      policy["taxonomy_mapping"] == { "mode" => "source_attribution" } &&
        policy["author_mapping"] == { "mode" => "source_attribution" }
    end

    def publication_profiles(platform, directions)
      return [] if Array(directions).exclude?("from_discourse")

      case platform
      when "statamic"
        %w[statamic_db statamic_flat statamic_ssg]
      when "discourse"
        ["discourse_as_publisher"]
      else
        [platform]
      end
    end

    def require_available_catalog_item!(catalog, segment_type, identifier)
      items = catalog.segments.find_by(segment_type: segment_type)&.items || []
      return if items.any? { |item| item["id"] == identifier && item["available"] }

      raise ArgumentError, "publication policy references an unavailable #{segment_type} item"
    end

    def require_available_native_limit!(catalog, native_limit_policy)
      items = catalog.segments.find_by(segment_type: "native_limits")&.items || []
      return if items.any? do |item|
        item["available"] &&
          item["maximum_bytes"] == native_limit_policy["maximum_bytes"] &&
          item["overflow_behavior"] == native_limit_policy["overflow_behavior"]
      end

      raise ArgumentError, "publication policy references an unavailable native limit"
    end

    def referenced_mapping_ids(mapping)
      values = Array(mapping["items"]).filter_map { |item| item["destination"] }
      values << mapping["destination_id"] if mapping["destination_id"].present?
      values.uniq
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
        publication_active: ConnectionCapability.publication_active?(connection),
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
            segments: catalog.segments.order(:segment_type).index_by(&:segment_type).transform_values(&:items),
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
