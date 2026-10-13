# frozen_string_literal: true

module DiscussionBridge
  class CmsWorkController < ::ApplicationController
    INPUT_TYPES = {
      "claim" => "Claim",
      "renew" => "Renew",
      "acknowledge" => "Ack",
      "fail" => "Failure",
      "prepare" => "StaticPreparation",
      "finalize" => "StaticFinalize",
      "abort" => "StaticAbort"
    }.freeze
    requires_plugin DiscussionBridge::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :prevent_response_caching
    before_action :validate_transport
    before_action :authenticate_content_connection
    before_action :validate_typed_input

    rescue_from CmsProtocol::Error do |error|
      render_error(error.code)
    end

    rescue_from SourceEdition::Unavailable do
      render_error("source_ineligible")
    end

    rescue_from SourceEdition::InvalidForumName do
      render_error("forum_configuration_invalid")
    end

    def claim
      respond(coordinator.claim(@input))
    end

    def show
      CmsProtocol.validate!("UUID", params[:work_id])
      respond(coordinator.query(params[:work_id]))
    end

    %i[renew acknowledge fail prepare finalize abort].each do |operation|
      define_method(operation) do
        respond(coordinator.public_send(operation, params[:work_id], @input))
      end
    end

    private

    def prevent_response_caching
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
    end

    def render_error(code)
      status =
        CmsProtocol::SCHEMA
          .fetch("errors")
          .find { |item| item.fetch("code") == code }
          .fetch("http")
      render json: {
               outcome: "rejected",
               code: code,
               retryable: CmsWorkCoordinator::TRANSIENT_CODES.include?(code),
               retry_after_seconds: nil,
               correlation_id: nil,
               core_fallback: false
             },
             status: status
    end

    def coordinator
      @coordinator ||=
        CmsWorkCoordinator.new(
          @content_connection,
          authenticated_secret_digest: @authenticated_secret_digest
        )
    end

    def respond(result)
      if result.status == 204
        head :no_content
      else
        response.headers["Cache-Control"] = "no-store"
        render json: result.body, status: result.status
      end
    end

    def validate_transport
      query = request.query_string
      unless query.empty?
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
        @unexpected_query = true
      end
      encoding = request.headers["Content-Encoding"]
      unless encoding.nil? || encoding == "identity"
        CmsProtocol.reject!("unsupported_media_type")
      end
      body = request.body.read(65_537).to_s
      request.body.rewind
      if request.get?
        CmsProtocol.reject!("invalid_field") unless body.empty?
        return
      end
      media = request.headers["Content-Type"].to_s
      unless media.match?(
               %r{\Aapplication/json(?:\s*;\s*charset\s*=\s*(?:UTF-8|"UTF-8"))?\z}i
             )
        CmsProtocol.reject!("unsupported_media_type")
      end
      @raw_body = body
      CmsProtocol.parse_json(body, reject_negative_zero: false)
    rescue ArgumentError
      CmsProtocol.reject!("invalid_field")
    end

    def authenticate_content_connection
      public_id = request.headers["X-DiscussionBridge-Connection"]
      secret = request.headers["X-DiscussionBridge-Secret"]
      if public_id.blank? || secret.blank?
        CmsProtocol.reject!("authentication_required")
      end
      unless public_id.is_a?(String) && public_id.bytesize <= 64 &&
               secret.is_a?(String)
        CmsProtocol.reject!("authentication_failed")
      end
      @content_connection =
        DiscussionBridgeContentConnection.find_by(public_id: public_id)
      unless @content_connection&.authenticate_secret?(secret)
        CmsProtocol.reject!("authentication_failed")
      end
      unless @content_connection.enabled
        CmsProtocol.reject!("connection_disabled")
      end
      @authenticated_secret_digest = @content_connection.secret_digest
    end

    def validate_typed_input
      validate_no_query!
      @input =
        CmsProtocol.parse_json(
          @raw_body,
          type: INPUT_TYPES.fetch(action_name)
        ) unless request.get?
    end

    def validate_no_query!
      CmsProtocol.reject!("unknown_field") if @unexpected_query
    end
  end
end
