# frozen_string_literal: true

module DiscussionBridge
  # Native login/session/CSRF protection applies; this is intentionally outside
  # Core's staff-only admin area. Content Connection credentials are insufficient.
  class SupportWorkspaceController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    prepend_view_path File.expand_path("../../views", __dir__)
    include SupportControllerInput
    before_action :ensure_logged_in
    skip_before_action :check_xhr, only: [:show, :client]
    # The fixed GET script has no user payload and must support classic script loading.
    skip_before_action :verify_authenticity_token, only: [:client]

    def show
      @workspace = operations.workspace(after: params[:after_id] || 0)
      response.headers["Cache-Control"] = "no-store"
      if request.format.json?
        support_json({ workspace: @workspace })
      else
        render :show, layout: false
      end
    end

    def client
      # Fixed plugin asset, no caller-controlled filesystem path or diagnostics.
      response.headers["Cache-Control"] = "no-store"
      response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
      render plain: File.read(File.expand_path("../../../public/javascripts/support.js", __dir__)), content_type: "application/javascript"
    end

    def check
      support_json(operations.attention(params[:id], "check", support_input))
    end

    def retry_selected
      support_json(operations.attention(params[:id], "retry", support_input))
    end

    def select_topic
      support_json(operations.select_topic(params[:id], support_input))
    end

    def synchronize
      support_json(operations.synchronize(params[:id], support_input))
    end

    private

    def operations
      SupportOperations.new(current_user)
    end
  end
end
