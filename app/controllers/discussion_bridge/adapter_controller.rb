# frozen_string_literal: true

module DiscussionBridge
  class AdapterController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    wrap_parameters false
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required

    before_action :establish_correlation
    before_action :require_contract_version
    before_action :require_canonical_https_origin
    before_action :require_json_body
    before_action :require_bounded_body
    before_action :require_known_query_fields
    before_action :require_known_body_fields
    before_action :require_matching_body_correlation
    before_action :ensure_bridge_enabled
    before_action :authenticate_content_connection

    rescue_from StandardError do |error|
      Rails.logger.error("[DiscussionBridge] adapter request failed: #{error.class.name}")
      render_protocol_error("internal_error")
    end
    rescue_from AdapterRequestBoundary::Error, with: :render_boundary_error
    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render_protocol_error("invalid_json")
    end
    rescue_from ActionController::ParameterMissing, Discourse::InvalidParameters do
      render_protocol_error("validation_failed")
    end
    rescue_from ActiveRecord::RecordNotFound do
      render_protocol_error("not_found")
    end
    rescue_from ActiveRecord::RecordInvalid, ArgumentError do
      render_protocol_error("validation_failed")
    end

    private

    def establish_correlation
      supplied = request.headers[AdapterRequestBoundary::CORRELATION_HEADER]
      @correlation_id = if AdapterRequestBoundary.valid_correlation?(supplied)
        supplied
      else
        SecureRandom.uuid
      end
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        AdapterRequestBoundary.valid_correlation?(supplied)
    end

    def require_contract_version
      return if request.headers[AdapterRequestBoundary::CONTRACT_HEADER] == DiscussionBridge::CONTRACT_VERSION

      raise AdapterRequestBoundary::Error, "contract_version_mismatch"
    end

    def require_canonical_https_origin
      configured = URI.parse(Discourse.base_url)
      nondefault_port = ![80, 443].include?(configured.port)
      valid = request.ssl? && request.host == configured.host &&
        (!nondefault_port || request.port == configured.port)
      raise AdapterRequestBoundary::Error, "policy_denied" unless valid
    rescue URI::InvalidURIError
      raise AdapterRequestBoundary::Error, "policy_denied"
    end

    def require_json_body
      return unless request.post? || request.put? || request.patch?
      return if request.media_type == "application/json"

      raise AdapterRequestBoundary::Error, "unsupported_media_type"
    end

    def require_bounded_body
      maximum = maximum_json_bytes
      return unless maximum
      raise AdapterRequestBoundary::Error, "request_too_large" if request.raw_post.bytesize > maximum
    end

    def require_known_query_fields
      unknown = request.query_parameters.keys.map(&:to_s) - allowed_query_fields
      raise AdapterRequestBoundary::Error, "unknown_field" if unknown.any?
    end

    def require_known_body_fields
      return unless request.post? || request.put? || request.patch?

      unknown = request.request_parameters.keys.map(&:to_s) - allowed_body_fields
      raise AdapterRequestBoundary::Error, "unknown_field" if unknown.any?

      require_known_nested_body_fields
    end

    def require_matching_body_correlation
      return unless request.post? || request.put? || request.patch?

      supplied = body_correlation_id
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        AdapterRequestBoundary.valid_correlation?(supplied) && supplied == @correlation_id
    end

    def ensure_bridge_enabled
      return if SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled

      raise AdapterRequestBoundary::Error, "temporarily_unavailable"
    end

    def authenticate_content_connection
      @content_connection = ContentConnectionAuthenticator.call(
        request,
        allow_disabled: allow_disabled_connection?,
      )
      raise AdapterRequestBoundary::Error, "authentication_failed" unless @content_connection
    end

    def allow_disabled_connection?
      false
    end

    def maximum_json_bytes
      nil
    end

    def allowed_query_fields
      []
    end

    def allowed_body_fields
      []
    end

    def require_known_nested_body_fields
    end

    def body_correlation_id
      request.request_parameters["correlation_id"]
    end

    def render_protocol_json(payload, status: :ok)
      response.set_header(AdapterRequestBoundary::CORRELATION_HEADER, @correlation_id)
      render json: payload.merge(correlation_id: @correlation_id), status: status
    end

    def render_protocol_error(error_code)
      unless @correlation_id
        supplied = request.headers[AdapterRequestBoundary::CORRELATION_HEADER]
        @correlation_id = if AdapterRequestBoundary.valid_correlation?(supplied)
          supplied
        else
          SecureRandom.uuid
        end
      end
      response.set_header(AdapterRequestBoundary::CORRELATION_HEADER, @correlation_id)
      render json: AdapterRequestBoundary.error_payload(error_code, @correlation_id),
             status: AdapterRequestBoundary::ERROR_STATUSES.fetch(error_code)
    end

    def render_boundary_error(error)
      render_protocol_error(error.error_code)
    end
  end
end
