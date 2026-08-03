# frozen_string_literal: true

module DiscussionBridge
  class HealthController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def show
      render json: DiscussionBridge::HealthStatus.call
    end
  end
end
