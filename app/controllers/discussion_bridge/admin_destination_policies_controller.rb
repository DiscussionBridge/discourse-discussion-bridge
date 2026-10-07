# frozen_string_literal: true

module DiscussionBridge
  class AdminDestinationPoliciesController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def update
      raise Discourse::InvalidAccess unless SiteSetting.discussion_bridge_enabled
      raise AdapterRequestBoundary::Error.new("unsupported_media_type") unless request.media_type == "application/json"
      value = AdapterRequestBoundary.parse(request.body.read(AdapterRequestBoundary::MAX_JSON_BYTES + 1))
      DestinationPolicy.object!(value, ["destination_policy"])
      connection = DiscussionBridgeContentConnection.find(params[:id])
      policy = DestinationPolicy.approve!(connection: connection, definition: value.fetch("destination_policy"), actor: current_user)
      render json: { destination_policy: policy.definition, policy_revision: policy.policy_revision,
        approved_by_id: policy.approved_by_id }
    rescue AdapterRequestBoundary::Error => error
      render json: { error_code: error.error_code }, status: AdapterRequestBoundary::ERROR_STATUSES.fetch(error.error_code)
    end
  end
end
