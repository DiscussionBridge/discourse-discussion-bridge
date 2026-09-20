# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  class DestinationMapping
    CATEGORY_POLICIES = %w[hold default].freeze
    TAG_POLICIES = %w[hold omit].freeze
    AUTHORSHIP_POLICIES = %w[service_author fixed].freeze
    SLUG_POLICIES = %w[platform_default source_title topic_id].freeze
    Result = Data.define(:mapping, :revision)

    def self.call(raw, connection:, catalog: connection.platform_catalog,
                  catalog_revision: connection.platform_catalog_revision)
      value = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
      catalog ||= {}
      raise ArgumentError, "platform catalog is required" if catalog.blank?
      containers = Array(catalog["containers"]).index_by { |item| item["id"] }
      taxonomies = Array(catalog["taxonomies"]).index_by { |item| item["id"] }
      authors = Array(catalog["authors"]).index_by { |item| item["id"] }
      terms = taxonomies.each_with_object({}) do |(taxonomy_id, taxonomy), result|
        Array(taxonomy["terms"]).each { |term| result[[taxonomy_id, term["id"]]] = term }
      end

      category_mappings = Array(value["category_mappings"]).map do |item|
        source_id = Integer(item["source_category_id"].to_s, 10)
        destination_id = item["destination_container_id"].to_s
        raise ArgumentError, "unknown public source category" unless
          Category.exists?(id: source_id, read_restricted: false)
        raise ArgumentError, "unknown destination container" unless containers.key?(destination_id)
        { "source_category_id" => source_id, "destination_container_id" => destination_id }
      end
      tag_mappings = Array(value["tag_mappings"]).map do |item|
        source_id = Integer(item["source_tag_id"].to_s, 10)
        taxonomy_id = item["destination_taxonomy_id"].to_s
        term_id = item["destination_term_id"].to_s
        raise ArgumentError, "unknown source tag" unless Tag.exists?(id: source_id)
        raise ArgumentError, "unknown destination taxonomy term" unless terms.key?([taxonomy_id, term_id])
        {
          "source_tag_id" => source_id,
          "destination_taxonomy_id" => taxonomy_id,
          "destination_term_id" => term_id,
        }
      end
      ensure_unique!(category_mappings, "source_category_id")
      ensure_unique!(tag_mappings, "source_tag_id")

      category_policy = value["unmapped_category_policy"].to_s.presence || "hold"
      tag_policy = value["unmapped_tag_policy"].to_s.presence || "omit"
      raise ArgumentError, "invalid unmapped category policy" if CATEGORY_POLICIES.exclude?(category_policy)
      raise ArgumentError, "invalid unmapped tag policy" if TAG_POLICIES.exclude?(tag_policy)
      default_id = value["default_destination_container_id"].to_s.presence
      raise ArgumentError, "default destination container is required" if category_policy == "default" && !default_id
      raise ArgumentError, "unknown default destination container" if default_id && !containers.key?(default_id)
      mode = value["presentation_mode"].to_s.presence || "native"
      raise ArgumentError, "unsupported presentation mode" if Array(catalog["presentation_modes"]).exclude?(mode)
      authorship_policy = value["authorship_policy"].to_s.presence || "service_author"
      raise ArgumentError, "invalid destination authorship policy" if
        AUTHORSHIP_POLICIES.exclude?(authorship_policy)
      destination_author_id = value["destination_author_id"].to_s.presence
      if authorship_policy == "fixed"
        raise ArgumentError, "destination author is required" unless destination_author_id
        raise ArgumentError, "unknown destination author" unless authors.key?(destination_author_id)
      else
        service_author_id = catalog["service_author_id"]
        if destination_author_id && destination_author_id != service_author_id
          raise ArgumentError, "destination author does not match the platform service author"
        end
        destination_author_id = service_author_id
        raise ArgumentError, "platform service author is unavailable" unless authors.key?(destination_author_id)
      end
      slug_policy = value["slug_policy"].to_s.presence || "platform_default"
      raise ArgumentError, "invalid destination URL policy" if SLUG_POLICIES.exclude?(slug_policy)

      referenced_container_ids = (
        category_mappings.map { |item| item.fetch("destination_container_id") } + [default_id]
      ).compact.uniq.sort
      referenced_term_ids = tag_mappings.map do |item|
        [item.fetch("destination_taxonomy_id"), item.fetch("destination_term_id")]
      end.sort
      referenced_taxonomy_ids = referenced_term_ids.map(&:first).uniq
      referenced_container_ids.each do |container_id|
        supported = Array(containers.fetch(container_id)["taxonomy_ids"])
        raise ArgumentError, "destination taxonomy is unsupported by a mapped container" if
          (referenced_taxonomy_ids - supported).any?
      end
      capability_contract = {
        "containers" => referenced_container_ids.map do |id|
          containers.fetch(id).except("label")
        end,
        "taxonomy_terms" => referenced_term_ids.map do |taxonomy_id, term_id|
          {
            "taxonomy_id" => taxonomy_id,
            "taxonomy" => taxonomies.fetch(taxonomy_id).except("label", "terms"),
            "term" => terms.fetch([taxonomy_id, term_id]).except("label"),
          }
        end,
        "presentation_mode" => mode,
        "authorship_policy" => authorship_policy,
        "author" => destination_author_id && authors.fetch(destination_author_id).except("label"),
        "slug_policy" => slug_policy,
        "capabilities" => catalog["capabilities"] || {},
        "limits" => catalog["limits"] || {},
      }
      capabilities = capability_contract.fetch("capabilities")
      raise ArgumentError, "platform does not support publication updates" unless capabilities["updates"]
      raise ArgumentError, "platform cannot hold or unpublish revoked content" unless
        capabilities["drafts"] || capabilities["unpublish"]

      mapping = {
        "catalog_revision" => catalog_revision,
        "category_mappings" => category_mappings.sort_by { |item| item["source_category_id"] },
        "tag_mappings" => tag_mappings.sort_by { |item| item["source_tag_id"] },
        "unmapped_category_policy" => category_policy,
        "default_destination_container_id" => default_id,
        "unmapped_tag_policy" => tag_policy,
        "presentation_mode" => mode,
        "authorship_policy" => authorship_policy,
        "destination_author_id" => destination_author_id,
        "slug_policy" => slug_policy,
        "capability_contract" => capability_contract,
      }.compact
      revision = Digest::SHA256.hexdigest(JSON.generate(deep_sort(mapping.except("catalog_revision"))))
      Result.new(mapping: mapping, revision: revision)
    end

    def self.valid_against_catalog?(raw, connection:, catalog:, catalog_revision:)
      call(
        raw,
        connection: connection,
        catalog: catalog,
        catalog_revision: catalog_revision,
      )
    rescue ArgumentError
      nil
    end

    def self.resolve(connection:, topic:)
      mapping = connection.destination_mapping || {}
      reasons = []
      if mapping.blank? || mapping["catalog_revision"] != connection.platform_catalog_revision
        return { state: "attention", reasons: ["destination_mapping_stale"] }
      end
      category = Array(mapping["category_mappings"]).find do |item|
        item["source_category_id"] == topic.category_id
      end
      container_id = category&.fetch("destination_container_id", nil)
      container_id ||= mapping["default_destination_container_id"] if
        mapping["unmapped_category_policy"] == "default"
      reasons << "destination_category_unmapped" unless container_id

      tag_map = Array(mapping["tag_mappings"]).index_by { |item| item["source_tag_id"] }
      destination_terms = topic.tags.filter_map { |tag| tag_map[tag.id] }
        .sort_by do |item|
          [item.fetch("source_tag_id"), item.fetch("destination_taxonomy_id"), item.fetch("destination_term_id")]
        end
      if mapping["unmapped_tag_policy"] == "hold" && topic.tags.any? { |tag| !tag_map.key?(tag.id) }
        reasons << "destination_tag_unmapped"
      end
      {
        state: reasons.empty? ? "ready" : "attention",
        reasons: reasons,
        catalog_revision: connection.platform_catalog_revision,
        mapping_revision: connection.destination_mapping_revision,
        destination_container_id: container_id,
        destination_terms: destination_terms,
        presentation_mode: mapping["presentation_mode"],
        authorship_policy: mapping["authorship_policy"],
        destination_author_id: mapping["destination_author_id"],
        slug_policy: mapping["slug_policy"],
        limits: effective_limits(mapping.dig("capability_contract", "limits")),
      }
    end

    def self.effective_limits(raw)
      limits = raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
      receiver_limit = BridgeRecordRequest::MAX_CONTENT_HTML_BYTES
      platform_limit = limits["content_bytes"].to_i
      platform_limit = receiver_limit unless platform_limit.positive?
      limits.merge("content_bytes" => [receiver_limit, platform_limit].min)
    end

    def self.ensure_unique!(items, key)
      values = items.map { |item| item.fetch(key) }
      raise ArgumentError, "duplicate #{key}" unless values.uniq == values
    end

    def self.deep_sort(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, deep_sort(value[key])] }
      when Array then value.map { |item| deep_sort(item) }
      else value
      end
    end

    private_class_method :effective_limits, :ensure_unique!, :deep_sort
  end
end
