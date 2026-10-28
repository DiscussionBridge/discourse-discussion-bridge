# frozen_string_literal: true

module DiscussionBridge
  class CmsAdminInspectionController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    before_action :validate_transport

    rescue_from CmsProtocol::Error do |error|
      spec = CmsProtocol::ERRORS.fetch(error.code)
      response.headers["Cache-Control"] = "no-store"
      render json: { outcome: "rejected", code: error.code, retryable: spec.fetch("retryable"), core_fallback: false }, status: spec.fetch("http")
    end

    def preview
      CmsProtocol.reject!("unknown_field") unless (@query.keys - ["topic_id"]).empty?
      respond(inspection_store.preview(@query.fetch("topic_id") { CmsProtocol.reject!("invalid_field") }))
    end

    def catalog
      respond(inspection_store.catalog(@query))
    end

    private

    def inspection_store
      CmsProtocol.validate!("CoreId", params[:id])
      connection = DiscussionBridgeContentConnection.find_by(id: params[:id])
      CmsProtocol.reject!("resource_not_found") unless connection
      CmsAdminInspectionStore.new(connection, actor: current_user, guardian: guardian)
    end

    def respond(result)
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      render json: result.body, status: result.status
    end

    def validate_transport
      CmsProtocol.reject!("invalid_field") unless request.get? && request.body.read(1).to_s.empty?
      encoding = request.headers["Content-Encoding"]
      CmsProtocol.reject!("unsupported_media_type") unless encoding.nil? || encoding == "identity"
      query = request.query_string
      CmsProtocol.reject!("invalid_field") if query.bytesize > 8192 || query.match?(/%(?![0-9a-fA-F]{2})/)
      pairs = URI.decode_www_form(query, Encoding::UTF_8)
      unless pairs.all? { |key, value| key.valid_encoding? && value.valid_encoding? } && pairs.map(&:first).uniq.size == pairs.size
        CmsProtocol.reject!("invalid_field")
      end
      @query = pairs.to_h
    rescue ArgumentError
      CmsProtocol.reject!("invalid_field")
    end
  end
end
