# frozen_string_literal: true

module DiscussionBridge
  class CmsAdminDeliveryController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    PAGE_SIZE = 25
    MAX_PAGE = 10_000
    before_action :validate_transport

    # Retain the native administrator/session/XHR checks. Adapter credentials
    # cannot substitute for a native administrator.
    rescue_from CmsProtocol::Error do |error|
      spec = CmsProtocol::ERRORS.fetch(error.code)
      response.headers["Cache-Control"] = "no-store"
      render json: { outcome: "rejected", code: error.code, retryable: spec.fetch("retryable") },
             status: spec.fetch("http")
    end

    def index
      CmsProtocol.validate!("CoreId", params[:id])
      connection = DiscussionBridgeContentConnection.find_by(id: params[:id])
      CmsProtocol.reject!("resource_not_found") unless connection
      DiscussionBridgeContentConnection.transaction do
        connection.lock!
        scope = DiscussionBridgeCmsMapping.where(content_connection_id: connection.id)
        total = scope.count
        rows = scope.includes(:content_connection, content_binding: { bridge_record: :topic })
          .order(:id).offset((@page - 1) * PAGE_SIZE).limit(PAGE_SIZE)
          .map { |mapping| CmsDeliveryProjection.call(mapping) }
        body = { deliveries: rows, page: @page, pages: [(total.to_f / PAGE_SIZE).ceil, 1].max,
                 total: total }
        CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > 262_144
        response.headers["Cache-Control"] = "no-store"
        render json: body
      end
    end

    private

    def validate_transport
      CmsProtocol.reject!("invalid_field") unless request.get?
      CmsProtocol.reject!("invalid_field") unless request.body.read(1).to_s.empty?
      query = request.query_string
      CmsProtocol.reject!("invalid_field") if query.bytesize > 1024
      CmsProtocol.reject!("invalid_field") if query.match?(/%(?![0-9a-fA-F]{2})/)
      pairs = URI.decode_www_form(query, Encoding::UTF_8)
      unless pairs.all? { |key, value| key.valid_encoding? && value.valid_encoding? }
        CmsProtocol.reject!("invalid_field")
      end
      CmsProtocol.reject!("invalid_field") if pairs.map(&:first).uniq.size != pairs.size
      CmsProtocol.reject!("unknown_field") unless pairs.all? { |key, _| key == "page" }
      value = pairs.to_h.fetch("page", "1")
      unless value.match?(/\A[1-9][0-9]{0,4}\z/) && value.to_i <= MAX_PAGE
        CmsProtocol.reject!("invalid_field")
      end
      @page = value.to_i
    rescue ArgumentError
      CmsProtocol.reject!("invalid_field")
    end
  end
end

