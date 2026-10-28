# frozen_string_literal: true

module DiscussionBridge
  class CmsAdminAttentionController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    before_action :validate_input

    rescue_from CmsProtocol::Error do |error|
      definition = CmsProtocol::ERRORS.fetch(error.code)
      response.headers["Cache-Control"] = "no-store"
      render json: { outcome: "rejected", code: error.code, retryable: definition.fetch("retryable"),
        retry_after_seconds: nil, correlation_id: nil, core_fallback: false }, status: definition.fetch("http")
    end

    def check
      render_result(store.check(actor: current_user, input: @input))
    end

    def retry_selected
      render_result(store.retry_selected(actor: current_user, input: @input))
    end

    private

    def store
      CmsProtocol.validate!("CoreId", params[:id])
      connection = DiscussionBridgeContentConnection.find_by(id: params[:id])
      CmsProtocol.reject!("resource_not_found") unless connection
      CmsAttentionRecovery.new(connection)
    end

    def render_result(result)
      response.headers["Cache-Control"] = "no-store"
      render json: result.body, status: result.status
    end

    # Inherit native administrator/session/CSRF/XHR protection. Content
    # Connection headers cannot stand in for the current administrator.
    def validate_input
      CmsProtocol.reject!("invalid_field") unless request.post? && request.query_string.empty?
      encoding = request.headers["Content-Encoding"]
      CmsProtocol.reject!("unsupported_media_type") unless encoding.nil? || encoding == "identity"
      unless request.headers["Content-Type"].to_s.match?(%r{\Aapplication/json(?:\s*;\s*charset\s*=\s*(?:UTF-8|"UTF-8"))?\z}i)
        CmsProtocol.reject!("unsupported_media_type")
      end
      raw = request.body.read(65_537).to_s
      request.body.rewind
      type = action_name == "check" ? "AttentionAdminCheck" : "AttentionAdminRetry"
      @input = CmsProtocol.parse_json(raw, type: type)
    end
  end
end
