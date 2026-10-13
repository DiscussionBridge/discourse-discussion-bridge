# frozen_string_literal: true

module DiscussionBridge
  module CmsConfiguration
    FIELDS = %w[profile destination_origin publication_lane native_capabilities policy].freeze

    def self.forum_name!
      value =
        (
          if ENV.key?("DISCUSSIONBRIDGE_FORUM_NAME")
            ENV.fetch("DISCUSSIONBRIDGE_FORUM_NAME")
          else
            SiteSetting.title
          end
        )
      CmsProtocol.validate!("Label", value)
      value
    rescue CmsProtocol::Error
      CmsProtocol.reject!("forum_configuration_invalid")
    end

    def self.validate!(connection, config)
      CmsProtocol.reject!("invalid_field") unless config.is_a?(Hash)
      CmsProtocol.reject!("unknown_field") if (config.keys - FIELDS).any?
      CmsProtocol.reject!("invalid_field") unless FIELDS.all? { |field| config.key?(field) }
      CmsProtocol.validate!("CmsProfile", config.fetch("profile"))
      CmsProtocol.validate!("Url", config.fetch("destination_origin"))
      CmsProtocol.validate!("Lane", config.fetch("publication_lane"))
      CmsProtocol.validate!("NativeCapabilities", config.fetch("native_capabilities"))
      policy = config.fetch("policy")
      CmsProtocol.validate!("Policy", policy)
      origin = config.fetch("destination_origin")
      uri = URI.parse(origin)
      unless (uri.path.empty? || uri.path == "/") && uri.query.nil?
        CmsProtocol.reject!("invalid_field")
      end
      canonical_origin = CmsProtocol.url_key(origin).delete_suffix("/")
      profile = config.fetch("profile")
      expected_platform = profile.start_with?("statamic_") ? "statamic" : profile
      unless connection.platform == expected_platform &&
               connection.allowed_origins.include?(canonical_origin) &&
               connection.allows_lane?(config.fetch("publication_lane"))
        CmsProtocol.reject!("scope_denied")
      end
      if (policy.fetch("include_topic_ids") & policy.fetch("exclude_topic_ids")).any?
        CmsProtocol.reject!("invalid_field")
      end
      categories = policy.fetch("category_ids")
      unless (
               if policy.fetch("selection") == "categories"
                 categories.any?
               else
                 categories.empty?
               end
             )
        CmsProtocol.reject!("invalid_field")
      end
      if policy.fetch("existing_record_adoption") == "disabled" &&
           policy.fetch("adoptable_resource_ids").any?
        CmsProtocol.reject!("invalid_field")
      end
      capabilities = config.fetch("native_capabilities")
      unless capabilities.fetch("supported_presentations").include?(
               policy.fetch("presentation_mode"),
             ) && capabilities.fetch("publication_kind") == policy.fetch("publication_kind")
        CmsProtocol.reject!("presentation_unsupported")
      end
      config
    end

    def self.destination_url!(connection, config, url)
      CmsProtocol.validate!("Url", url)
      uri = URI.parse(CmsProtocol.url_key(url))
      origin = "https://#{uri.host}#{uri.port == 443 ? "" : ":#{uri.port}"}"
      configured = CmsProtocol.url_key(config.fetch("destination_origin")).delete_suffix("/")
      unless origin == configured && connection.allowed_origins.include?(origin)
        CmsProtocol.reject!("scope_denied")
      end
      url
    end

    def self.current!(connection, require_enabled: false, required_direction: "from_discourse")
      CmsProtocol.reject!("connection_disabled") unless connection.enabled
      if required_direction && !connection.allows_direction?(required_direction)
        CmsProtocol.reject!("scope_denied")
      end
      config = connection.cms_configuration
      CmsProtocol.reject!("scope_denied") unless config
      validate!(connection, config)
      if require_enabled
        unless config.fetch("policy").fetch("enabled") && SiteSetting.discussion_bridge_enabled &&
                 SiteSetting.discussion_bridge_endpoint_enabled &&
                 SiteSetting.discussion_bridge_publisher_enabled
          CmsProtocol.reject!("scope_denied")
        end
        # Exact selected catalog IDs are checked at each publication action.
        # Descriptive reads, owned withdrawal and failure reporting retain their
        # own scope checks without requiring publication assignments.
      end
      config
    end

    def self.eligible?(topic, policy)
      return false unless SourceEdition.publicly_available?(topic)
      id = topic.id.to_s
      return false if policy.fetch("exclude_topic_ids").include?(id)
      return false if !topic.visible && !policy.fetch("include_unlisted")
      policy.fetch("include_topic_ids").include?(id) || policy.fetch("selection") == "all_public" ||
        policy.fetch("category_ids").include?(topic.category_id.to_s)
    end
  end
end
