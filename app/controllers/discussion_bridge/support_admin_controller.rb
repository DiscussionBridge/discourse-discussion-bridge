# frozen_string_literal: true

module DiscussionBridge
  class SupportAdminController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    prepend_view_path File.expand_path("../../views", __dir__)
    include SupportControllerInput
    skip_before_action :check_xhr, only: [:show]

    # Existing admin controllers/routes keep their native guards. This page
    # additionally reloads and verifies the actual administrator for each write.
    def show
      @support = SupportWorkflow.admin_data(current_user)
      response.headers["Cache-Control"] = "no-store"
      if request.format.json?
        support_json({ support: @support })
      else
        render :show, layout: false
      end
    end

    def update
      input = support_envelope("support", %w[enabled])
      support_json({ support: SupportWorkflow.enable!(current_user, input.fetch("enabled")) })
    end

    def request_assistance
      input = support_envelope("support_request", SupportWorkflow::REQUEST_FIELDS + ["reviewed"])
      support_json({ request: SupportWorkflow.request!(current_user, input) }, status: 202)
    end

    def grant
      input = support_envelope("support_grant", %w[username])
      support_json({ grant: SupportWorkflow.grant!(current_user, input.fetch("username")) })
    end

    def revoke
      raise SupportWorkflow::Error, "Revocation accepts no extra fields." unless support_input.empty?
      support_json({ grant: SupportWorkflow.revoke!(current_user, params[:id]) })
    end
  end
end
