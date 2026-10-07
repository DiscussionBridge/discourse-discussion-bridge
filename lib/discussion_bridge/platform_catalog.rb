# frozen_string_literal: true

module DiscussionBridge
  module PlatformCatalog
    EMPTY_REVISION = "catalog:empty"
    SEGMENTS = {
      "containers" => %w[id name kind available], "taxonomies" => %w[id name hierarchical available],
      "terms" => %w[id taxonomy_id name parent_id available], "authors" => %w[id name available],
      "presentation_modes" => %w[id name available],
      "native_limits" => %w[id name maximum_bytes overflow_behavior available],
    }.freeze
    CURSOR_PURPOSE = "discussionbridge-catalog-alpha22"

    def self.current(connection, profile)
      DiscussionBridgeCatalogRevision.where(content_connection_id: connection.id, platform_profile: profile).order(id: :desc).first
    end

    def self.validate_items!(segment, items)
      fields = SEGMENTS[segment]
      DestinationPolicy.fail_with unless fields && items.is_a?(Array) && items.size <= 100
      items.each do |item|
        DestinationPolicy.object!(item, fields)
        DestinationPolicy.string!(item["id"])
        DestinationPolicy.string!(item["name"], 200)
        DestinationPolicy.fail_with if [true, false].exclude?(item["available"])
        case segment
        when "containers"
          DestinationPolicy.string!(item["kind"], 100)
        when "taxonomies"
          DestinationPolicy.fail_with if [true, false].exclude?(item["hierarchical"])
        when "terms"
          DestinationPolicy.string!(item["taxonomy_id"])
          DestinationPolicy.string!(item["parent_id"]) unless item["parent_id"].nil?
        when "presentation_modes"
          DestinationPolicy.fail_with if DestinationPolicy::MODES.exclude?(item["id"])
        when "native_limits"
          DestinationPolicy.fail_with unless item["maximum_bytes"].is_a?(Integer) &&
            item["maximum_bytes"].between?(1, 9_007_199_254_740_991) && DestinationPolicy::OVERFLOW.include?(item["overflow_behavior"])
        end
      end
      DestinationPolicy.fail_with unless items.map { |item| item["id"] }.uniq.size == items.size
    end

    # Caller owns the current connection lock/authentication recheck.
    def self.replace!(connection, request)
      DestinationPolicy.object!(request, %w[platform_profile base_catalog_revision segments correlation_id])
      profile = request.fetch("platform_profile")
      DestinationPolicy.profile!(connection, profile)
      DestinationPolicy.string!(request.fetch("base_catalog_revision"))
      segments = request.fetch("segments")
      DestinationPolicy.fail_with unless segments.is_a?(Array) && segments.size.between?(1, SEGMENTS.size)
      segments.each do |segment|
        DestinationPolicy.object!(segment, %w[segment_type items])
        validate_items!(segment["segment_type"], segment["items"])
      end
      supplied = segments.map { |segment| segment.fetch("segment_type") }
      DestinationPolicy.fail_with unless supplied.uniq == supplied
      previous = current(connection, profile)
      DestinationPolicy.fail_with("catalog_revision_conflict") unless request.fetch("base_catalog_revision") == (previous&.public_id || EMPTY_REVISION)
      # Exactly six bounded segments; no traversal of publication/source populations.
      values = previous ? previous.catalog_items.pluck(:segment_type, :item_id, :value).to_h { |type, id, value| [[type, id], value] } : {}
      old_values = values.deep_dup
      segments.each do |segment|
        type = segment.fetch("segment_type")
        values.delete_if { |(key_type, _id), _value| key_type == type }
        segment.fetch("items").each { |item| values[[type, item.fetch("id")]] = item.deep_dup }
      end
      # History reserves stable identity. Catalog refresh neither changes policy
      # nor creates publication work. Unavailable references remain identifiable.
      DiscussionBridgeDestinationPolicy.current(connection).where(platform_profile: profile).limit(100).pluck(:definition).each do |policy|
        DestinationPolicy.references(policy).each do |key|
          values[key] ||= old_values[key]&.merge("available" => false)
        end
        old_values.each do |key, item|
          next unless key.first == "native_limits" && item.slice("maximum_bytes", "overflow_behavior") == policy.fetch("native_limit_policy")
          values[key] ||= item.merge("available" => false)
        end
      end
      values.compact!
      # One bounded distinct identity projection, not one lookup per item and
      # not loading historical segments or full catalog/source populations.
      identity_scope = DiscussionBridgeCatalogItem.joins(:catalog_revision).where(
        discussion_bridge_catalog_revisions: { content_connection_id: connection.id, platform_profile: profile },
      )
      sought = values.keys.group_by(&:first).map do |type, keys|
        identity_scope.where(segment_type: type, item_id: keys.map(&:last))
      end.reduce { |left, right| left.or(right) }
      identities = sought ? sought.select("DISTINCT ON (segment_type, item_id) discussion_bridge_catalog_items.*")
        .order(:segment_type, :item_id, :id).limit(601).to_h { |item| [[item.segment_type, item.item_id], item.value] } : {}
      values.each do |(type, id), item|
        original = identities[[type, id]]
        identity_fields = type == "containers" ? ["kind"] : type == "terms" ? ["taxonomy_id"] : []
        if original && original.slice(*identity_fields) != item.slice(*identity_fields)
          DestinationPolicy.fail_with("identity_conflict")
        end
      end
      SEGMENTS.each_key do |type|
        DestinationPolicy.fail_with if values.keys.count { |key| key.first == type } > 100
      end
      validate_references!(values)
      revision = DiscussionBridgeCatalogRevision.create!(content_connection: connection, platform_profile: profile,
        public_id: "catalog:#{SecureRandom.hex(16)}", created_at: Time.now.utc)
      values.each do |(type, id), item|
        revision.catalog_items.create!(segment_type: type, item_id: id, value: item)
      end
      { catalog_revision: revision.public_id, platform_profile: profile, accepted_segments: supplied,
        correlation_id: request.fetch("correlation_id") }
    end

    def self.validate_references!(values)
      values.each do |(type, id), item|
        next unless type == "terms" && item["available"]
        taxonomy = values[["taxonomies", item["taxonomy_id"]]]
        DestinationPolicy.fail_with unless taxonomy && taxonomy["available"]
        next if item["parent_id"].nil?
        seen = [id]
        parent_id = item["parent_id"]
        while parent_id
          parent = values[["terms", parent_id]]
          DestinationPolicy.fail_with unless parent && parent["available"] && parent["taxonomy_id"] == item["taxonomy_id"] && !seen.include?(parent_id)
          seen << parent_id
          parent_id = parent["parent_id"]
        end
      end
    end

    def self.page(connection, query, correlation)
      profile, segment = query.values_at("platform_profile", "segment_type")
      DestinationPolicy.profile!(connection, profile)
      DestinationPolicy.fail_with unless SEGMENTS.key?(segment)
      revision = current(connection, profile)
      public_id = revision&.public_id || EMPTY_REVISION
      if query.key?("catalog_revision") && query["catalog_revision"] != public_id
        DestinationPolicy.fail_with("catalog_revision_conflict")
      end
      limit = 100
      if query.key?("limit")
        raw = query["limit"]
        DestinationPolicy.fail_with unless raw.is_a?(String) && /\A[1-9]\d{0,2}\z/.match?(raw) && Integer(raw).between?(1, 100)
        limit = Integer(raw)
      end
      context = { "connection_id" => connection.public_id, "platform_profile" => profile,
        "segment_type" => segment, "catalog_revision" => public_id, "policy_revision" => SourceConnectionScope.revision(connection) }
      position = 0
      if query.key?("cursor")
        raw = query["cursor"]
        DestinationPolicy.fail_with unless raw.is_a?(String) && raw.bytesize.between?(1, 4096)
        value = verifier.verified(raw, purpose: CURSOR_PURPOSE)
        DestinationPolicy.fail_with("cursor_snapshot_mismatch") unless query["catalog_revision"] == public_id &&
          value.is_a?(Hash) && value.keys.sort == (context.keys + ["position"]).sort && value.except("position") == context &&
          value["position"].is_a?(Integer) && value["position"].positive?
        position = value.fetch("position")
      end
      relation = revision ? revision.catalog_items.where(segment_type: segment) : DiscussionBridgeCatalogItem.none
      rows = relation.where("id > ?", position).order(:id).limit(limit).pluck(:id, :value)
      loop do
        last = rows.empty? ? position : rows.last.first
        complete = !relation.where("id > ?", last).exists?
        value = { catalog_revision: public_id, platform_profile: profile, segment_type: segment,
          items: rows.map(&:last), next_cursor: complete ? nil : verifier.generate(context.merge("position" => last), purpose: CURSOR_PURPOSE),
          complete: complete, correlation_id: correlation }
        return value if JSON.generate(value).bytesize <= AdapterRequestBoundary::MAX_JSON_BYTES
        DestinationPolicy.fail_with("integrity_failed") if rows.size <= 1
        rows.pop
      end
    end

    def self.verifier
      Rails.application.message_verifier(:discussion_bridge_platform_catalog)
    end
  end
end
