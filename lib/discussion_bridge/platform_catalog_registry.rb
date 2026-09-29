# frozen_string_literal: true

module DiscussionBridge
  class PlatformCatalogRegistry
    Page = Data.define(:catalog_revision, :items, :next_cursor, :complete)

    def self.page(connection:, platform_profile:, segment_type:, catalog_revision:, cursor:, limit:)
      new(connection: connection, platform_profile: platform_profile).page(
        segment_type: segment_type,
        catalog_revision: catalog_revision,
        cursor: cursor,
        limit: limit,
      )
    end

    def self.update(connection:, platform_profile:, base_catalog_revision:, segments:)
      new(connection: connection, platform_profile: platform_profile).update(
        base_catalog_revision: base_catalog_revision,
        segments: segments,
      )
    end

    def self.catalog(connection:, platform_profile:, catalog_revision:)
      new(connection: connection, platform_profile: platform_profile).send(
        :find_catalog,
        catalog_revision,
      )
    end

    def initialize(connection:, platform_profile:)
      @connection = connection
      @platform_profile = platform_profile
      @policies = PlatformCatalogProtocol.validate_profile!(connection, platform_profile)
    end

    def page(segment_type:, catalog_revision:, cursor:, limit:)
      raise AdapterRequestBoundary::Error, "validation_failed" if
        PlatformCatalogProtocol::SEGMENT_TYPES.exclude?(segment_type)

      revision, offset = resolve_page(
        segment_type: segment_type,
        catalog_revision: catalog_revision,
        cursor: cursor,
      )
      items = segment_items(revision, segment_type).sort_by { |item| item.fetch("id") }
      page_items = items.slice(offset, limit) || []
      next_offset = offset + page_items.length
      complete = next_offset >= items.length
      next_cursor = unless complete
        SourceCursor.issue(
          kind: "catalog",
          payload: {
            "connection_id" => @connection.public_id,
            "platform_profile" => @platform_profile,
            "segment_type" => segment_type,
            "catalog_revision" => revision,
            "offset" => next_offset,
          },
        )
      end
      Page.new(
        catalog_revision: revision,
        items: page_items,
        next_cursor: next_cursor,
        complete: complete,
      )
    end

    def update(base_catalog_revision:, segments:)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        PlatformCatalogProtocol.valid_label?(base_catalog_revision)
      values = segments.map { |segment| PlatformCatalogProtocol.validate_segment!(segment) }
      types = values.map { |segment| segment.fetch("segment_type") }
      raise AdapterRequestBoundary::Error, "validation_failed" if values.empty? || types.uniq.length != types.length

      replacement = nil
      DiscussionBridgePlatformCatalog.transaction do
        @connection.lock!
        current = current_catalog
        current_revision = current&.catalog_revision || initial_revision
        raise AdapterRequestBoundary::Error, "catalog_revision_conflict" unless
          current_revision == base_catalog_revision

        new_revision = "catalog:#{@platform_profile}:#{SecureRandom.hex(16)}"
        current&.update!(current: false)
        replacement = @connection.platform_catalogs.create!(
          platform_profile: @platform_profile,
          catalog_revision: new_revision,
          current: true,
        )
        existing = current ? current.segments.index_by(&:segment_type) : {}
        PlatformCatalogProtocol::SEGMENT_TYPES.each do |segment_type|
          supplied = values.find { |segment| segment.fetch("segment_type") == segment_type }
          items = if supplied
            replacement_items(
              segment_type,
              previous: existing[segment_type]&.items || [],
              supplied: supplied.fetch("items"),
            )
          else
            existing[segment_type]&.items || []
          end
          replacement.segments.create!(segment_type: segment_type, items: items)
        end
      end
      replacement
    rescue ActiveRecord::RecordNotUnique
      raise AdapterRequestBoundary::Error, "catalog_revision_conflict"
    end

    private

    def resolve_page(segment_type:, catalog_revision:, cursor:)
      if cursor.present?
        payload = SourceCursor.read(cursor, kind: "catalog")
        valid = payload["connection_id"] == @connection.public_id &&
          payload["platform_profile"] == @platform_profile &&
          payload["segment_type"] == segment_type &&
          payload["catalog_revision"].is_a?(String) &&
          payload["offset"].is_a?(Integer) && payload["offset"] >= 0
        raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch" unless valid
        raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch" if
          catalog_revision.present? && catalog_revision != payload["catalog_revision"]

        return [payload.fetch("catalog_revision"), payload.fetch("offset")]
      end

      revision = catalog_revision.presence || current_catalog&.catalog_revision || initial_revision
      raise AdapterRequestBoundary::Error, "not_found" unless find_catalog(revision) || revision == initial_revision

      [revision, 0]
    end

    def current_catalog
      @connection.platform_catalogs.find_by(platform_profile: @platform_profile, current: true)
    end

    def find_catalog(revision)
      @connection.platform_catalogs.find_by(
        platform_profile: @platform_profile,
        catalog_revision: revision,
      )
    end

    def initial_revision
      revisions = @policies.map { |policy| policy.fetch("catalog_revision") }.uniq
      raise AdapterRequestBoundary::Error, "policy_denied" unless revisions.one?

      revisions.first
    end

    def segment_items(revision, segment_type)
      catalog = find_catalog(revision)
      return [] unless catalog

      catalog.segments.find_by(segment_type: segment_type)&.items || []
    end

    def replacement_items(segment_type, previous:, supplied:)
      previous_by_id = previous.index_by { |item| item.fetch("id") }
      supplied_by_id = supplied.index_by { |item| item.fetch("id") }
      verify_stable_identities!(segment_type, previous_by_id, supplied_by_id)
      referenced_ids(segment_type).each do |identifier|
        next if supplied_by_id.key?(identifier)
        next unless previous_by_id.key?(identifier)

        supplied_by_id[identifier] = previous_by_id.fetch(identifier).merge("available" => false)
      end
      supplied_by_id.values.sort_by { |item| item.fetch("id") }
    end

    def verify_stable_identities!(segment_type, previous, supplied)
      immutable = {
        "containers" => %w[kind],
        "taxonomies" => %w[hierarchical],
        "terms" => %w[taxonomy_id],
      }.fetch(segment_type, [])
      (previous.keys & supplied.keys).each do |identifier|
        changed = immutable.any? do |field|
          previous.fetch(identifier)[field] != supplied.fetch(identifier)[field]
        end
        raise AdapterRequestBoundary::Error, "identity_conflict" if changed
      end
    end

    def referenced_ids(segment_type)
      @policies.flat_map do |policy|
        case segment_type
        when "containers"
          [policy.dig("container_mapping", "destination")]
        when "terms"
          Array(policy.dig("taxonomy_mapping", "items")).filter_map do |item|
            item.stringify_keys["destination"]
          end
        when "authors"
          [policy.dig("author_mapping", "destination_id")] +
            Array(policy.dig("author_mapping", "items")).filter_map do |item|
              item.stringify_keys["destination"]
            end
        when "presentation_modes"
          [policy["presentation_mode"]]
        else
          []
        end
      end.compact.uniq
    end
  end
end
