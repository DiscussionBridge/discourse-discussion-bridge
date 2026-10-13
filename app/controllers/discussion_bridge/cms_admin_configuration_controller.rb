# frozen_string_literal: true

module DiscussionBridge
  class CmsAdminConfigurationController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    before_action :validate_transport

    # Native administrator/session/CSRF/XHR checks are deliberately retained.
    # Content Connection credentials and descriptive capabilities grant no UI
    # administration or policy-writing authority.
    rescue_from CmsProtocol::Error do |error|
      spec = CmsProtocol::ERRORS.fetch(error.code)
      response.headers["Cache-Control"] = "no-store"
      render json: {
               outcome: "rejected",
               code: error.code,
               retryable: spec.fetch("retryable"),
               retry_after_seconds: nil,
               correlation_id: nil,
               core_fallback: false
             },
             status: spec.fetch("http")
    end

    def show
      respond(authority_store.administrative_configuration(actor: current_user))
    end

    def update
      respond(authority_store.configure!(actor: current_user, input: @input))
    end

    private

    def authority_store
      CmsProtocol.validate!("CoreId", params[:id])
      connection = DiscussionBridgeContentConnection.find_by(id: params[:id])
      CmsProtocol.reject!("resource_not_found") unless connection
      CmsAuthorityStore.new(connection)
    end

    def respond(result)
      response.headers["Cache-Control"] = "no-store"
      render json: result.body, status: result.status
    end

    def validate_transport
      unless request.query_string.empty?
        query = request.query_string
        if query.match?(/%(?![0-9a-fA-F]{2})/)
          CmsProtocol.reject!("invalid_field")
        end
        pairs = URI.decode_www_form(query, Encoding::UTF_8)
        if pairs.any? { |key, value|
             !key.valid_encoding? || !value.valid_encoding?
           }
          CmsProtocol.reject!("invalid_field")
        end
        if pairs.map(&:first).uniq.size != pairs.size
          CmsProtocol.reject!("invalid_field")
        end
        CmsProtocol.reject!("unknown_field")
      end
      encoding = request.headers["Content-Encoding"]
      unless encoding.nil? || encoding == "identity"
        CmsProtocol.reject!("unsupported_media_type")
      end
      raw = request.body.read(65_537).to_s
      request.body.rewind
      if request.get?
        CmsProtocol.reject!("invalid_field") unless raw.empty?
        return
      end
      CmsProtocol.reject!("invalid_field") unless request.put?
      media = request.headers["Content-Type"].to_s
      unless media.match?(
               %r{\Aapplication/json(?:\s*;\s*charset\s*=\s*(?:UTF-8|"UTF-8"))?\z}i
             )
        CmsProtocol.reject!("unsupported_media_type")
      end
      @input = CmsProtocol.parse_json(raw)
    rescue ArgumentError
      CmsProtocol.reject!("invalid_field")
    end
  end
end
