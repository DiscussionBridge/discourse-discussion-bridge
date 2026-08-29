# frozen_string_literal: true

module DiscussionBridge
  class HealthController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def show
      render json: DiscussionBridge::ProductOverview.call
    end

    def support_bundle
      render json: {
        generated_at: Time.zone.now.iso8601,
        overview: DiscussionBridge::ProductOverview.call,
        reconciliation: DiscussionBridge::BridgeReconciliationIndex.call(page: 1),
      }
    end
  end
end
