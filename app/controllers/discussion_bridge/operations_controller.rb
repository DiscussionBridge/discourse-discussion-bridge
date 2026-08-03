# frozen_string_literal: true

module DiscussionBridge
  class OperationsController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def index
      render json: DiscussionBridge::OperationsIndex.call(
        kind: params[:kind],
        query: params[:query],
        filter: params[:filter],
        page: params[:page],
      )
    end
  end
end
