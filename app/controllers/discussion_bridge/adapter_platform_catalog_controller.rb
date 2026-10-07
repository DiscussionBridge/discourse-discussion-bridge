# frozen_string_literal: true

module DiscussionBridge
  class AdapterPlatformCatalogController < AdapterController
    prepend_before_action :prevent_catalog_caching

    def show
      with_current_connection do
        value = PlatformCatalog.page(@content_connection, request.query_parameters, @correlation_id)
        # Bind ETag to the exact bounded page, including correlation and cursor.
        body = JSON.generate(value)
        response.headers["ETag"] = %Q["#{Digest::SHA256.hexdigest(body)}"]
        render json: body
      end
    end

    def update
      with_current_connection do
        render json: JSON.generate(PlatformCatalog.replace!(@content_connection, @catalog_request))
      end
    end

    private

    def permitted_query_fields
      action_name == "show" ? %w[platform_profile segment_type cursor limit catalog_revision] : []
    end

    def parse_request_body(value)
      DestinationPolicy.object!(value, %w[platform_profile base_catalog_revision segments correlation_id])
      DestinationPolicy.fail_with unless value["correlation_id"] == @correlation_id
      @catalog_request = value
    end

    def prevent_catalog_caching
      response.headers["Cache-Control"] = "private, must-revalidate"
    end
  end
end
