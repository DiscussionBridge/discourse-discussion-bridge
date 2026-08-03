# frozen_string_literal: true

module DiscussionBridge
  class ConnectionsController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_json_request
    before_action :ensure_plugin_enabled
    before_action :ensure_endpoint_enabled
    before_action :authenticate_connection

    def create
      request_data = connection_params.to_h.symbolize_keys
      actor = User.find_by(username_lower: SiteSetting.discussion_bridge_service_username.downcase)
      lane_resolution = LanePolicies.resolve(
        value: SiteSetting.discussion_bridge_lane_policies,
        lane: request_data[:lane],
      )
      authority = ForumAuthority.call(
        actor: actor,
        category_id: lane_resolution.category_id || SiteSetting.discussion_bridge_effective_category_id,
        tags: lane_resolution.tags || SiteSetting.discussion_bridge_effective_tags,
      ) if actor
      policy = PolicyEvaluator.call(
        request: request_data,
        settings: policy_settings,
        actor: actor,
        authority: authority,
        lane_resolution: lane_resolution,
      )
      result = CreateOrResolve.call(
        request: request_data,
        policy: policy,
        repository: ConnectionRepository.new,
        topic_creator: TopicCreator.new,
        audit_writer: AuditWriter.new(request: request_data),
      )
      render json: result_payload(result), status: response_status(result)
    rescue ActionController::ParameterMissing, ArgumentError
      render json: rejection("invalid_request"), status: :unprocessable_entity
    end

    private

    def ensure_json_request
      raise Discourse::InvalidParameters.new(:format) unless request.format.json?
    end

    def ensure_plugin_enabled
      render json: { outcome: "rejected", reason: "plugin_disabled", core_fallback: false }, status: :not_found unless SiteSetting.discussion_bridge_enabled
    end

    def ensure_endpoint_enabled
      render json: { outcome: "rejected", reason: "endpoint_disabled", core_fallback: false }, status: :service_unavailable unless SiteSetting.discussion_bridge_endpoint_enabled
    end

    def authenticate_connection
      expected_id = SiteSetting.discussion_bridge_connection_id
      expected_secret = SiteSetting.discussion_bridge_connection_secret
      supplied_id = request.headers["X-DiscussionBridge-Connection"]
      supplied_secret = request.headers["X-DiscussionBridge-Secret"]

      authorized = expected_id.present? && expected_secret.present? &&
        ActiveSupport::SecurityUtils.secure_compare(supplied_id.to_s, expected_id) &&
        ActiveSupport::SecurityUtils.secure_compare(supplied_secret.to_s, expected_secret)
      render json: { outcome: "rejected", reason: "unauthorized", core_fallback: false }, status: :unauthorized unless authorized
    end

    def connection_params
      connection = params.require(:connection)
      connection.require(:connection_id)
      connection.require(:source_url)
      connection.require(:title)
      connection.permit(
        :connection_id,
        :adapter_id,
        :source_url,
        :title,
        :visibility,
        :lane,
        :correlation_id,
        :category_id,
        tags: [],
      )
    end

    def policy_settings
      PolicyEvaluator::Settings.new(
        enabled: SiteSetting.discussion_bridge_enabled,
        endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
        connection_id: SiteSetting.discussion_bridge_connection_id,
        trusted_origins: SiteSetting.discussion_bridge_trusted_origins,
        service_username: SiteSetting.discussion_bridge_service_username,
      )
    end

    def result_payload(result)
      {
        outcome: result.outcome,
        reason: result.reason,
        topic_id: result.topic_id,
        requested: result.requested,
        effective: result.effective,
        correlation_id: result.correlation_id,
        core_fallback: false,
      }
    end

    def response_status(result)
      return :created if result.outcome == "created"
      return :ok if result.outcome == "resolved"
      return :conflict if result.outcome == "reconciliation_required"

      :unprocessable_entity
    end

    def rejection(reason)
      { outcome: "rejected", reason: reason, core_fallback: false }
    end
  end
end
