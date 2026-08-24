# frozen_string_literal: true

module DiscussionBridge
  class ReconciliationController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def index
      render json: ReconciliationIndex.call(
        query: params[:query],
        severity: params[:severity],
        page: params[:page],
      )
    rescue ArgumentError
      render json: { error: "invalid_reconciliation_query" }, status: :unprocessable_entity
    end

    def authorize_retry
      result = RetryAuthorization.call(
        mapping_id: params.require(:mapping_id),
        administrator: current_user,
      )
      render json: {
        authorized: result.authorized,
        reason: result.reason,
        mapping_id: result.mapping.id,
      }, status: result.authorized ? :ok : :unprocessable_entity
    end

    def revoke_retry
      result = RetryAuthorization.revoke(
        mapping_id: params.require(:mapping_id),
        administrator: current_user,
      )
      render json: {
        authorized: result.authorized,
        reason: result.reason,
        mapping_id: result.mapping.id,
      }, status: result.reason == "retry_authorization_revoked" ? :ok : :unprocessable_entity
    end
  end
end
