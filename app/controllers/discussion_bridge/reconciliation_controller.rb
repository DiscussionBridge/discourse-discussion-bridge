# frozen_string_literal: true

module DiscussionBridge
  class ReconciliationController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def index
      render json: BridgeReconciliationIndex.call(
        query: params[:query],
        severity: params[:severity],
        page: params[:page],
      )
    rescue ArgumentError
      render json: { error: "invalid_reconciliation_query" }, status: :unprocessable_entity
    end

    def report
      render json: BridgeReconciliationIndex.call(page: 1)
    end

  end
end
