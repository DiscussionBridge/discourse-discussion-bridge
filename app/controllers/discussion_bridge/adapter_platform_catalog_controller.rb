# frozen_string_literal: true

module DiscussionBridge
  class AdapterPlatformCatalogController < AdapterController
    def show
      profile = params[:platform_profile].to_s
      segment_type = params[:segment_type].to_s
      limit = PlatformCatalogProtocol.valid_limit(params[:limit])
      page = PlatformCatalogRegistry.page(
        connection: @content_connection,
        platform_profile: profile,
        segment_type: segment_type,
        catalog_revision: params[:catalog_revision],
        cursor: params[:cursor],
        limit: limit,
      )
      response.set_header("Cache-Control", "private, must-revalidate")
      response.set_header("ETag", %Q("#{Digest::SHA256.hexdigest([page.catalog_revision, segment_type, params[:cursor], limit].join("\n"))}"))
      render_protocol_json({
        catalog_revision: page.catalog_revision,
        platform_profile: profile,
        segment_type: segment_type,
        items: page.items,
        next_cursor: page.next_cursor,
        complete: page.complete,
      })
    end

    def update
      payload = raw_catalog_body
      required = PlatformCatalogProtocol::UPDATE_REQUIRED_FIELDS
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        required.all? { |field| payload.key?(field) }

      catalog = PlatformCatalogRegistry.update(
        connection: @content_connection,
        platform_profile: payload.fetch("platform_profile"),
        base_catalog_revision: payload.fetch("base_catalog_revision"),
        segments: payload.fetch("segments"),
      )
      response.set_header("Cache-Control", "private, no-store")
      render_protocol_json({
        catalog_revision: catalog.catalog_revision,
        platform_profile: catalog.platform_profile,
        accepted_segments: payload.fetch("segments").map { |segment| segment["segment_type"] },
      })
    end

    private

    def maximum_json_bytes
      action_name == "update" ? PlatformCatalogProtocol::MAXIMUM_JSON_BYTES : nil
    end

    def allowed_query_fields
      action_name == "show" ? PlatformCatalogProtocol::QUERY_FIELDS : []
    end

    def allowed_body_fields
      action_name == "update" ? PlatformCatalogProtocol::UPDATE_REQUIRED_FIELDS : []
    end

    def require_known_nested_body_fields
      return unless action_name == "update"

      segments = raw_catalog_body["segments"]
      return unless segments.is_a?(Array)

      segments.each do |segment|
        next unless segment.is_a?(Hash)
        raise AdapterRequestBoundary::Error, "unknown_field" if
          (segment.keys.map(&:to_s) - PlatformCatalogProtocol::SEGMENT_FIELDS).any?
        type = segment["segment_type"]
        items = segment["items"]
        next unless PlatformCatalogProtocol::ITEM_SCHEMAS.key?(type) && items.is_a?(Array)

        items.each do |item|
          next unless item.is_a?(Hash)
          raise AdapterRequestBoundary::Error, "unknown_field" if
            (item.keys.map(&:to_s) - PlatformCatalogProtocol::ITEM_SCHEMAS.fetch(type)).any?
        end
      end
    end

    def raw_catalog_body
      @raw_catalog_body ||= JSON.parse(request.raw_post)
    end
  end
end
