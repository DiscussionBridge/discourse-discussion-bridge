# frozen_string_literal: true

module DiscussionBridge
  class AdminPublicationRetriesController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def create
      raise Discourse::InvalidAccess unless SiteSetting.discussion_bridge_enabled
      raise AdapterRequestBoundary::Error.new("unsupported_media_type") unless request.media_type == "application/json"
      value = AdapterRequestBoundary.parse(request.body.read(AdapterRequestBoundary::MAX_JSON_BYTES + 1))
      connection = DiscussionBridgeContentConnection.find(params[:id])
      render json: PublicationRetry.accept!(connection: connection, public_id: params[:work_id], request: value, actor: current_user)
    rescue AdapterRequestBoundary::Error => error
      render json: { error_code: error.error_code }, status: AdapterRequestBoundary::ERROR_STATUSES.fetch(error.error_code)
    rescue ActiveRecord::RecordInvalid
      render json: { error_code: "validation_failed" }, status: :unprocessable_entity
    end
  end
end
