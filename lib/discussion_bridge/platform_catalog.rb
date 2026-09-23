# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  class PlatformCatalog
    MAX_BYTES = 240 * 1024
    MAX_CONTAINERS = 500
    MAX_TAXONOMIES = 100
    MAX_TERMS = 5_000
    MAX_AUTHORS = 500
    MAX_PATH_BYTES = 512
    ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]{0,254}\z/
    KINDS = %w[category collection section post_type content_type].freeze
    PRESENTATION_MODES = %w[simple full fullInteractive native].freeze
    CAPABILITY_KEYS = %w[updates unpublish drafts].freeze
    LIMIT_KEYS = %w[content_bytes title_bytes slug_bytes].freeze
    DEFAULT_LIMITS = {
      "content_bytes" => DiscussionBridge::BridgeRecordRequest::MAX_PUBLICATION_CONTENT_HTML_BYTES,
      "title_bytes" => DiscussionBridge::ConnectionRequest::MAX_TITLE_BYTES,
      "slug_bytes" => 255,
    }.freeze

    Result = Data.define(:catalog, :revision, :display_revision)

    def self.call(raw, platform:)
      value = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
      raise ArgumentError, "platform catalog is too large" if JSON.generate(value).bytesize > MAX_BYTES
      raise ArgumentError, "platform catalog schema is invalid" unless value["schema_version"] == 1
      raise ArgumentError, "platform catalog does not match connection" unless value["platform"] == platform

      containers = Array(value["containers"])
      taxonomies = Array(value["taxonomies"])
      authors = Array(value["authors"])
      modes = Array(value["presentation_modes"])
      raise ArgumentError, "too many platform containers" if containers.length > MAX_CONTAINERS
      raise ArgumentError, "too many platform taxonomies" if taxonomies.length > MAX_TAXONOMIES
      raise ArgumentError, "too many platform authors" if authors.length > MAX_AUTHORS
      raise ArgumentError, "invalid presentation mode" unless modes.uniq == modes &&
        (modes - PRESENTATION_MODES).empty?

      normalized_containers = containers.map do |item|
        normalized = normalize_item(item, allowed_kinds: KINDS, allow_path: true)
        taxonomy_ids = Array(item["taxonomy_ids"]).map(&:to_s)
        raise ArgumentError, "invalid container taxonomy ids" unless
          taxonomy_ids.uniq == taxonomy_ids && taxonomy_ids.all? { |id| ID_PATTERN.match?(id) }
        normalized.merge("taxonomy_ids" => taxonomy_ids.sort)
      end.sort_by { |item| item.fetch("id") }
      validate_hierarchy!(normalized_containers, "container")

      term_count = 0
      normalized_taxonomies = taxonomies.map do |taxonomy|
        normalized = normalize_item(taxonomy, allowed_kinds: %w[taxonomy])
        terms = Array(taxonomy["terms"])
        term_count += terms.length
        normalized_terms = terms.map { |term| normalize_item(term, allowed_kinds: %w[term]) }
          .sort_by { |term| term.fetch("id") }
        validate_hierarchy!(normalized_terms, "taxonomy term")
        normalized.merge("terms" => normalized_terms)
      end.sort_by { |taxonomy| taxonomy.fetch("id") }
      raise ArgumentError, "too many platform taxonomy terms" if term_count > MAX_TERMS
      ensure_unique!(normalized_containers, "container")
      ensure_unique!(normalized_taxonomies, "taxonomy")
      taxonomy_ids = normalized_taxonomies.map { |taxonomy| taxonomy.fetch("id") }
      normalized_containers.each do |container|
        raise ArgumentError, "unknown container taxonomy" if
          (container.fetch("taxonomy_ids") - taxonomy_ids).any?
      end
      normalized_taxonomies.each { |taxonomy| ensure_unique!(taxonomy.fetch("terms"), "taxonomy term") }
      normalized_authors = authors.map { |author| normalize_item(author, allowed_kinds: %w[author]) }
        .sort_by { |author| author.fetch("id") }
      ensure_unique!(normalized_authors, "author")
      service_author_id = value["service_author_id"].to_s.presence
      raise ArgumentError, "service author is required" unless service_author_id
      raise ArgumentError, "unknown service author" unless
        normalized_authors.any? { |author| author.fetch("id") == service_author_id }

      catalog = {
        "schema_version" => 1,
        "platform" => platform,
        "containers" => normalized_containers,
        "taxonomies" => normalized_taxonomies,
        "authors" => normalized_authors,
        "service_author_id" => service_author_id,
        "presentation_modes" => modes.sort,
        "capabilities" => normalize_capabilities(value["capabilities"]),
        "limits" => normalize_limits(value["limits"]),
        "inventory" => normalize_inventory(value["inventory"]),
      }
      display_canonical = JSON.generate(deep_sort(catalog))
      identity_canonical = JSON.generate(deep_sort(without_labels(catalog)))
      Result.new(
        catalog: catalog,
        revision: Digest::SHA256.hexdigest(identity_canonical),
        display_revision: Digest::SHA256.hexdigest(display_canonical),
      )
    rescue JSON::GeneratorError
      raise ArgumentError, "platform catalog is invalid"
    end

    def self.normalize_item(raw, allowed_kinds: nil, allow_path: false)
      value = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
      id = value["id"].to_s
      label = value["label"].to_s.strip
      kind = value["kind"].to_s.presence
      parent_id = value["parent_id"].to_s.presence
      path = value["path"].to_s.presence
      raise ArgumentError, "invalid platform object id" unless ID_PATTERN.match?(id)
      raise ArgumentError, "invalid platform object label" if
        label.blank? || label.bytesize > 255 || label.match?(/[\x00-\x1f\x7f]/)
      raise ArgumentError, "invalid platform object kind" if allowed_kinds && !allowed_kinds.include?(kind)
      raise ArgumentError, "invalid platform parent id" if parent_id && !ID_PATTERN.match?(parent_id)
      if path
        raise ArgumentError, "platform path is not supported here" unless allow_path
        raise ArgumentError, "invalid platform path" unless
          path.start_with?("/") && path.bytesize <= MAX_PATH_BYTES && !path.match?(/[\x00-\x1f\x7f]/)
      end
      {
        "id" => id,
        "label" => label,
        "kind" => kind,
        "parent_id" => parent_id,
        "path" => path,
      }.compact
    end

    def self.normalize_capabilities(raw)
      value = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h if raw.respond_to?(:to_h)
      value ||= {}
      valid_keys = (value.keys - CAPABILITY_KEYS).empty?
      valid_values = value.values.all? { |item| item == true || item == false }
      raise ArgumentError, "invalid platform capabilities" unless valid_keys && valid_values
      CAPABILITY_KEYS.to_h { |key| [key, value.fetch(key, false)] }
    end

    def self.normalize_limits(raw)
      value = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h if raw.respond_to?(:to_h)
      value ||= {}
      raise ArgumentError, "invalid platform limits" unless (value.keys - LIMIT_KEYS).empty?
      DEFAULT_LIMITS.merge(value).each_with_object({}) do |(key, item), result|
        integer = Integer(item.to_s, 10, exception: false)
        raise ArgumentError, "invalid platform #{key}" unless integer&.between?(1, 10 * 1024 * 1024)
        result[key] = integer
      end
    end

    def self.normalize_inventory(raw)
      value = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h if raw.respond_to?(:to_h)
      value ||= {}
      allowed = %w[authors_complete terms_complete authors_observed terms_observed]
      raise ArgumentError, "invalid platform inventory" unless (value.keys - allowed).empty?
      %w[authors_complete terms_complete].each do |key|
        raise ArgumentError, "invalid platform inventory" if [true, false].exclude?(value[key])
      end
      %w[authors_observed terms_observed].each do |key|
        raise ArgumentError, "invalid platform inventory" unless value[key].is_a?(Integer) && value[key] >= 0
      end
      raise ArgumentError, "platform inventory is incomplete" unless
        value["authors_complete"] && value["terms_complete"]
      value.slice(*allowed)
    end

    def self.validate_hierarchy!(items, label)
      by_id = items.index_by { |item| item.fetch("id") }
      items.each do |item|
        parent_id = item["parent_id"]
        next unless parent_id
        raise ArgumentError, "unknown #{label} parent" unless by_id.key?(parent_id)
        raise ArgumentError, "cyclic #{label} hierarchy" if parent_id == item.fetch("id")

        visited = { item.fetch("id") => true }
        cursor = parent_id
        while cursor
          raise ArgumentError, "cyclic #{label} hierarchy" if visited[cursor]
          visited[cursor] = true
          cursor = by_id.fetch(cursor)["parent_id"]
        end
      end
    end

    def self.ensure_unique!(items, label)
      ids = items.map { |item| item.fetch("id") }
      raise ArgumentError, "duplicate #{label} id" unless ids.uniq == ids
    end

    def self.without_labels(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key] = without_labels(item) unless key == "label"
        end
      when Array then value.map { |item| without_labels(item) }
      else value
      end
    end

    def self.deep_sort(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, deep_sort(value[key])] }
      when Array then value.map { |item| deep_sort(item) }
      else value
      end
    end

    private_class_method :normalize_item, :normalize_capabilities, :normalize_limits, :normalize_inventory,
                         :validate_hierarchy!, :ensure_unique!, :without_labels, :deep_sort
  end
end
