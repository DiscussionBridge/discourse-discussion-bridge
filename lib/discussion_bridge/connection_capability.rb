# frozen_string_literal: true

module DiscussionBridge
  module ConnectionCapability
    PRESENTATION_MODES = %w[simple full interactive].freeze
    PROFILES = %w[
      astro
      ghost
      hugo
      statamic_db
      statamic_flat
      statamic_ssg
      wordpress
      discourse_as_publisher
    ].freeze
    SUPPORTED_OPERATIONS = %w[resolve inventory claim renew acknowledge fail revocations catalog].freeze
    REQUIRED_FIELDS = %w[
      contract_version
      connection_id
      enabled
      directions
      lanes
      allowed_presentation_modes
      supported_operations
      bounds
      destination_policies
      catalog_required
      policy_revision
      correlation_id
    ].freeze
    POLICY_KEYS = %w[
      destination_policy_id
      profile
      presentation_mode
      container_mapping
      taxonomy_mapping
      author_mapping
      native_limit_policy
      catalog_revision
    ].freeze
    CONTAINER_MAPPING_KEYS = %w[source destination].freeze
    TAXONOMY_MAPPING_REQUIRED_KEYS = %w[mode].freeze
    TAXONOMY_MAPPING_OPTIONAL_KEYS = %w[items].freeze
    AUTHOR_MAPPING_REQUIRED_KEYS = %w[mode].freeze
    AUTHOR_MAPPING_OPTIONAL_KEYS = %w[destination_id items].freeze
    NATIVE_LIMIT_POLICY_KEYS = %w[maximum_bytes overflow_behavior].freeze
    MAPPING_MODES = %w[mapped_only source_attribution].freeze
    OVERFLOW_BEHAVIORS = %w[complete excerpt_with_read_more operator_attention].freeze
    STATIC_DEPLOYMENT_PROFILES = %w[astro hugo statamic_flat statamic_ssg].freeze
    BOUNDS = {
      resolve_json_bytes: 65_536,
      source_content_bytes: 16_777_216,
      claim_maximum_items: 32,
      lease_maximum_seconds: 14_400,
      catalog_segment_items: 100,
    }.freeze
    CONTROL_PATTERN = /[\x00-\x1f\x7f]/

    def self.payload(connection)
      raise AdapterRequestBoundary::Error, "temporarily_unavailable" unless configured?(connection)

      payload = {
        contract_version: DiscussionBridge::CONTRACT_VERSION,
        connection_id: connection.public_id,
        enabled: connection.enabled,
        directions: Array(connection.allowed_directions),
        lanes: Array(connection.allowed_lanes),
        allowed_presentation_modes: PRESENTATION_MODES,
        supported_operations: supported_operations(connection),
        bounds: BOUNDS,
        destination_policies: connection.destination_policies,
        catalog_required: connection.catalog_required,
        policy_revision: connection.policy_revision,
      }
      if connection.allows_direction?("from_discourse") || connection.network_enabled
        forum_name = ENV["DISCUSSIONBRIDGE_FORUM_NAME"]
        raise AdapterRequestBoundary::Error, "temporarily_unavailable" unless valid_label?(forum_name, 200)

        payload[:forum_name] = forum_name
      end
      payload
    end

    def self.configured?(connection)
      valid_label?(connection.policy_revision, 255) &&
        valid_destination_policies?(connection.destination_policies) &&
        policies_within_connection_scope?(connection)
    end

    def self.valid_destination_policies?(policies)
      return false unless policies.is_a?(Array) && policies.any? && policies.all? do |policy|
        policy.is_a?(Hash) && valid_policy?(policy.deep_stringify_keys)
      end

      identifiers = policies.map { |policy| policy.stringify_keys["destination_policy_id"] }
      identifiers.uniq.length == identifiers.length
    end

    def self.valid_policy_revision?(value)
      valid_label?(value, 255)
    end

    def self.static_deployment_policy?(policy)
      STATIC_DEPLOYMENT_PROFILES.include?(policy.deep_stringify_keys["profile"])
    end

    def self.policies_within_connection_scope?(connection)
      allowed_profiles = []
      allowed_profiles << "discourse_as_publisher" if connection.allows_direction?("to_discourse")
      if connection.allows_direction?("from_discourse")
        allowed_profiles.concat(
          case connection.platform
          when "statamic"
            %w[statamic_db statamic_flat statamic_ssg]
          when "discourse"
            ["discourse_as_publisher"]
          else
            [connection.platform]
          end,
        )
      end
      Array(connection.destination_policies).all? do |policy|
        allowed_profiles.include?(policy.stringify_keys["profile"])
      end
    end

    def self.valid_policy?(policy)
      return false unless exact_keys?(policy, POLICY_KEYS)
      return false unless valid_label?(policy["destination_policy_id"], 255)
      return false if PROFILES.exclude?(policy["profile"])
      return false if PRESENTATION_MODES.exclude?(policy["presentation_mode"])
      return false unless exact_keys?(policy["container_mapping"], CONTAINER_MAPPING_KEYS)
      return false unless valid_label?(policy.dig("container_mapping", "source"), 2048)
      return false unless valid_label?(policy.dig("container_mapping", "destination"), 2048)
      return false unless mapping_valid?(policy["taxonomy_mapping"], TAXONOMY_MAPPING_REQUIRED_KEYS + TAXONOMY_MAPPING_OPTIONAL_KEYS)
      return false unless mapping_valid?(policy["author_mapping"], AUTHOR_MAPPING_REQUIRED_KEYS + AUTHOR_MAPPING_OPTIONAL_KEYS)
      return false unless exact_keys?(policy["native_limit_policy"], NATIVE_LIMIT_POLICY_KEYS)
      maximum = policy.dig("native_limit_policy", "maximum_bytes")
      return false unless maximum.is_a?(Integer) && maximum.positive? && maximum <= 16_777_216
      return false if OVERFLOW_BEHAVIORS.exclude?(policy.dig("native_limit_policy", "overflow_behavior"))

      valid_label?(policy["catalog_revision"], 255)
    end
    private_class_method :valid_policy?

    def self.mapping_valid?(mapping, allowed_keys)
      return false unless mapping.is_a?(Hash)
      return false unless (mapping.keys.map(&:to_s) - allowed_keys).empty?
      return false unless mapping.key?("mode") && MAPPING_MODES.include?(mapping["mode"])

      true
    end
    private_class_method :mapping_valid?

    def self.exact_keys?(value, required)
      value.is_a?(Hash) && value.keys.map(&:to_s).sort == required.sort
    end
    private_class_method :exact_keys?

    def self.valid_label?(value, maximum)
      value.is_a?(String) && value.valid_encoding? && value.present? && value == value.strip &&
        value.bytesize <= maximum && !CONTROL_PATTERN.match?(value)
    end
    private_class_method :valid_label?

    def self.supported_operations(connection)
      return ["resolve"] unless connection.allows_direction?("from_discourse")

      SUPPORTED_OPERATIONS
    end
    private_class_method :supported_operations
  end
end
