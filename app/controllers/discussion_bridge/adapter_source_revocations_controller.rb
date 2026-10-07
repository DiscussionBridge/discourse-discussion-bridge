# frozen_string_literal: true

module DiscussionBridge
  class AdapterSourceRevocationsController < AdapterController
    requires_plugin PLUGIN_NAME
    prepend_before_action :prevent_source_caching

    def index
      render_notices { |reader| reader.page }
    end

    def show
      render_notices { |reader| reader.detail(resource_id: params[:resource_id]) }
    end

    private

    def prevent_source_caching
      response.headers["Cache-Control"] = "private, no-store"
    end

    def permitted_query_fields
      action_name == "index" ? %w[cursor limit high_water] : []
    end

    def render_notices
      @content_connection.with_lock do
        unless SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled &&
            @content_connection.enabled && @content_connection.authenticate_secret?(request.headers["X-DiscussionBridge-Secret"])
          raise AdapterRequestBoundary::Error.new("authentication_failed")
        end
        unless @content_connection.allows_direction?("from_discourse")
          raise AdapterRequestBoundary::Error.new("direction_denied")
        end
        # Withdrawals remain readable after source privacy/scope changes. Only
        # retained identity/revision notices, never private content, are exposed.
        render json: yield(SourceRevocations.new(connection: @content_connection, query: request.query_parameters,
          correlation_id: @correlation_id))
      end
    end
  end
end
