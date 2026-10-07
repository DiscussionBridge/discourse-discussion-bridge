# frozen_string_literal: true

module DiscussionBridge
  module DestinationPolicy
    PROFILES = %w[astro ghost hugo statamic_db statamic_flat statamic_ssg wordpress discourse_as_publisher].freeze
    MODES = %w[simple full interactive].freeze
    MAPPING_MODES = %w[mapped_only source_attribution].freeze
    OVERFLOW = %w[complete excerpt_with_read_more operator_attention].freeze
    FIELDS = %w[destination_policy_id profile presentation_mode container_mapping taxonomy_mapping author_mapping native_limit_policy catalog_revision].freeze

    def self.fail_with(code = "validation_failed")
      raise AdapterRequestBoundary::Error.new(code)
    end

    def self.object!(value, fields, optional = [])
      fail_with("unknown_field") unless value.is_a?(Hash) && (value.keys - fields - optional).empty?
      fail_with unless (fields - value.keys).empty?
    end

    def self.string!(value, maximum = 255)
      fail_with unless value.is_a?(String) && value.valid_encoding? && value.strip.present? &&
        value.bytesize <= maximum && !AdapterRequestBoundary::CONTROL_PATTERN.match?(value)
    end

    def self.profiles(connection)
      return %w[statamic_db statamic_flat statamic_ssg] if connection.platform == "statamic"
      return ["discourse_as_publisher"] if connection.platform == "discourse"
      [connection.platform] & PROFILES
    end

    def self.profile!(connection, profile)
      fail_with if PROFILES.exclude?(profile)
      fail_with("scope_denied") if profiles(connection).exclude?(profile)
    end

    def self.validate!(connection, definition)
      object!(definition, FIELDS)
      string!(definition["destination_policy_id"])
      string!(definition["catalog_revision"])
      profile!(connection, definition["profile"])
      fail_with if MODES.exclude?(definition["presentation_mode"])
      object!(definition["container_mapping"], %w[source destination])
      definition["container_mapping"].each_value { |value| string!(value) }
      %w[taxonomy_mapping author_mapping].each do |field|
        mapping = definition[field]
        optional = field == "author_mapping" ? %w[items destination_id] : %w[items]
        object!(mapping, ["mode"], optional)
        fail_with if MAPPING_MODES.exclude?(mapping["mode"])
        string!(mapping["destination_id"]) if mapping.key?("destination_id")
        next unless mapping.key?("items")
        items = mapping["items"]
        fail_with unless items.is_a?(Array) && items.size <= 1000
        items.each do |item|
          object!(item, %w[source destination])
          item.each_value { |value| string!(value) }
        end
        fail_with unless items.map { |item| item["source"] }.uniq.size == items.size
      end
      limit = definition["native_limit_policy"]
      object!(limit, %w[maximum_bytes overflow_behavior])
      fail_with unless limit["maximum_bytes"].is_a?(Integer) && limit["maximum_bytes"].between?(1, 9_007_199_254_740_991) &&
        OVERFLOW.include?(limit["overflow_behavior"])
      fail_with if JSON.generate(definition).bytesize > AdapterRequestBoundary::MAX_JSON_BYTES
    end

    # Called only by native admin configuration, never by adapter/catalog input.
    # Append a separately keyed revision. No legacy bindings or sibling policies change.
    def self.approve!(connection:, definition:, actor:)
      fail_with("policy_denied") unless actor&.admin? && actor.active? && !actor.staged? &&
        !actor.suspended? && !actor.silenced? && actor.id != Discourse::SYSTEM_USER_ID
      validate!(connection, definition)
      connection.with_lock do
        fail_with("scope_denied") unless connection.enabled && connection.allows_direction?("from_discourse")
        catalog = PlatformCatalog.current(connection, definition.fetch("profile"))
        fail_with("catalog_revision_conflict") unless catalog && catalog.public_id == definition.fetch("catalog_revision")
        policy_id = definition.fetch("destination_policy_id")
        previous = DiscussionBridgeDestinationPolicy.current(connection).find_by(destination_policy_id: policy_id)
        if previous&.definition == definition
          # An explicit repeat approval can start the additive queue for a
          # retained policy; migration/read/catalog discovery cannot do so.
          PublicationWorkProducer.start!(previous)
          return previous
        end
        if previous && previous.platform_profile != definition.fetch("profile")
          fail_with("identity_conflict")
        end
        fail_with if !previous && DiscussionBridgeDestinationPolicy.current(connection).limit(101).count >= 100
        availability!(definition, catalog)
        policy = DiscussionBridgeDestinationPolicy.create!(content_connection: connection, catalog_revision: catalog,
          approved_by: actor, destination_policy_id: policy_id, platform_profile: definition.fetch("profile"),
          policy_revision: "destination:#{SecureRandom.hex(16)}", definition: definition.deep_dup, created_at: Time.now.utc)
        PublicationWorkProducer.start!(policy)
        policy
      end
    end

    def self.references(definition)
      values = [["containers", definition.fetch("container_mapping").fetch("destination")],
        ["presentation_modes", definition.fetch("presentation_mode")]]
      Array(definition.fetch("taxonomy_mapping")["items"]).each { |item| values << ["terms", item.fetch("destination")] }
      author = definition.fetch("author_mapping")
      values << ["authors", author.fetch("destination_id")] if author.key?("destination_id")
      Array(author["items"]).each { |item| values << ["authors", item.fetch("destination")] }
      values.uniq
    end

    def self.availability!(definition, catalog)
      items = catalog.catalog_items.pluck(:segment_type, :item_id, :value).to_h { |segment, id, value| [[segment, id], value] }
      fail_with("policy_denied") unless references(definition).all? { |key| items[key]&.fetch("available") == true }
      limit = definition.fetch("native_limit_policy")
      fail_with("policy_denied") unless items.any? do |(segment, _id), item|
        segment == "native_limits" && item["available"] && limit == item.slice("maximum_bytes", "overflow_behavior")
      end
    end
  end
end
