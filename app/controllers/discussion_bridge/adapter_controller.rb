# frozen_string_literal: true

module DiscussionBridge
  class AdapterController < ::ApplicationController
    # Validate protocol headers first so the native enabled guard also returns
    # the contract error envelope rather than Core's generic disabled response.
    wrap_parameters false
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :validate_protocol_request
    requires_plugin PLUGIN_NAME

    rescue_from StandardError, with: :render_internal_error
    rescue_from AdapterRequestBoundary::Error, with: :render_protocol_error
    rescue_from ActiveRecord::RecordInvalid, ArgumentError, with: :render_validation_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from Discourse::InvalidAccess, with: :render_policy_denied
    rescue_from ::ApplicationController::PluginDisabled, with: :render_temporarily_unavailable

    private

    def validate_protocol_request
      supplied = request.headers["X-DiscussionBridge-Correlation"]
      valid_correlation = AdapterRequestBoundary.valid_correlation?(supplied)
      @correlation_id = valid_correlation ? supplied.dup.force_encoding(Encoding::UTF_8) : SecureRandom.uuid
      response.headers["X-DiscussionBridge-Correlation"] = @correlation_id
      raise AdapterRequestBoundary::Error.new("validation_failed") unless valid_correlation
      unless request.headers["X-DiscussionBridge-Contract"] == AdapterRequestBoundary::CONTRACT_VERSION
        raise AdapterRequestBoundary::Error.new("contract_version_mismatch")
      end
      base = URI.parse(Discourse.base_url)
      unless request.ssl? && request.host == base.host && [443, base.port].include?(request.port)
        raise AdapterRequestBoundary::Error.new("scope_denied")
      end
      raise AdapterRequestBoundary::Error.new("request_too_large") if request.query_string.bytesize > 8192
      permitted_query = action_name == "index" ? %w[page] : []
      unless (request.query_parameters.keys - permitted_query).empty?
        raise AdapterRequestBoundary::Error.new("unknown_field")
      end
      if request.post?
        unless request.media_type == "application/json"
          raise AdapterRequestBoundary::Error.new("unsupported_media_type")
        end
        if request.content_length && request.content_length > AdapterRequestBoundary::MAX_JSON_BYTES
          raise AdapterRequestBoundary::Error.new("request_too_large")
        end
        # Never materialize an unbounded raw_post before enforcing the wire bound.
        text = request.body.read(AdapterRequestBoundary::MAX_JSON_BYTES + 1)
        envelope = AdapterRequestBoundary.parse(text)
        unless envelope.is_a?(Hash) && envelope.keys == ["bridge_record"]
          raise AdapterRequestBoundary::Error.new("unknown_field")
        end
        @bridge_request = BridgeRecordRequest.call(envelope.fetch("bridge_record"))
        unless @bridge_request[:correlation_id] == @correlation_id
          raise AdapterRequestBoundary::Error.new("validation_failed")
        end
      elsif request.content_length.to_i.positive?
        raise AdapterRequestBoundary::Error.new("unknown_field")
      end
      unless SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled
        raise AdapterRequestBoundary::Error.new("temporarily_unavailable")
      end
      @content_connection = ContentConnectionAuthenticator.call(request)
      raise AdapterRequestBoundary::Error.new("authentication_failed") unless @content_connection
    end

    def render_protocol_error(error)
      render json: AdapterRequestBoundary.error_payload(error.error_code, @correlation_id),
             status: AdapterRequestBoundary::ERROR_STATUSES.fetch(error.error_code)
    end

    def render_validation_error(_error)
      render_protocol_error(AdapterRequestBoundary::Error.new("validation_failed"))
    end

    def render_not_found(_error)
      render_protocol_error(AdapterRequestBoundary::Error.new("not_found"))
    end

    def render_policy_denied(_error)
      render_protocol_error(AdapterRequestBoundary::Error.new("policy_denied"))
    end

    def render_temporarily_unavailable(_error)
      render_protocol_error(AdapterRequestBoundary::Error.new("temporarily_unavailable"))
    end

    def render_internal_error(_error)
      render_protocol_error(AdapterRequestBoundary::Error.new("internal_error"))
    end
  end
end
