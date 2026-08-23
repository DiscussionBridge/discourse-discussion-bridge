# frozen_string_literal: true

# name: discourse-discussion-bridge
# about: Forum-governed control plane for DiscussionBridge connections.
# meta_topic_id: 0
# version: 0.1.0.alpha.1
# authors: DiscussionBridge contributors
# url: https://discussionbridge.dev/
# required_version: 3.3.0

require_relative "lib/discussion_bridge/settings_validators"

enabled_site_setting :discussion_bridge_enabled
register_asset "stylesheets/common/discussion-bridge-comments-only.scss"
register_asset "stylesheets/common/discussion-bridge-admin-health.scss"

add_admin_route(
  "discussion_bridge.admin.title",
  "discourse-discussion-bridge",
  use_new_show_route: true,
)

Rails.application.config.filter_parameters << /discussion.?bridge.?secret/i

after_initialize do
  module ::DiscussionBridge
    PLUGIN_NAME = "discourse-discussion-bridge"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscussionBridge
    end
  end

  require_relative "lib/discussion_bridge/canonical_source"
  require_relative "lib/discussion_bridge/site_setting_label_formatter_extension"
  require_relative "lib/discussion_bridge/lane_policies"
  require_relative "lib/discussion_bridge/policy_evaluator"
  require_relative "lib/discussion_bridge/forum_authority"
  require_relative "lib/discussion_bridge/health_status"
  require_relative "lib/discussion_bridge/operations_index"
  require_relative "lib/discussion_bridge/reconciliation_index"
  require_relative "lib/discussion_bridge/retry_authorization"
  require_relative "lib/discussion_bridge/audit_state"
  require_relative "lib/discussion_bridge/connection_repository"
  require_relative "lib/discussion_bridge/topic_creator"
  require_relative "lib/discussion_bridge/audit_writer"
  require_relative "lib/discussion_bridge/create_or_resolve"
  require_relative "lib/discussion_bridge/comments_only_presenter"
  require_relative "app/models/discussion_bridge_connection"
  require_relative "app/models/discussion_bridge_audit_event"
  require_relative "app/controllers/discussion_bridge/connections_controller"
  require_relative "app/controllers/discussion_bridge/health_controller"
  require_relative "app/controllers/discussion_bridge/operations_controller"
  require_relative "app/controllers/discussion_bridge/reconciliation_controller"

  SiteSettings::LabelFormatter.singleton_class.prepend(
    DiscussionBridge::SiteSettingLabelFormatterExtension,
  ) unless SiteSettings::LabelFormatter.singleton_class <
    DiscussionBridge::SiteSettingLabelFormatterExtension

  module ::DiscussionBridge
    module EmbedControllerExtension
      def comments
        topic_id =
          if params[:topic_id].present?
            params[:topic_id]
          elsif params[:embed_url].present?
            TopicEmbed.topic_id_for_embed(params[:embed_url])
          end

        if params[:full_app].present?
          bridge_class = CommentsOnlyPresenter.redirect_class_name(
            topic_id: topic_id,
            full_app: true,
            existing_class_name: params[:class_name],
          )
          bridge_class.present? ? params[:class_name] = bridge_class : params.delete(:class_name)
        end

        super
      end
    end
  end

  EmbedController.prepend(DiscussionBridge::EmbedControllerExtension) unless
    EmbedController < DiscussionBridge::EmbedControllerExtension

  DiscussionBridge::Engine.routes.draw do
    post "/connections/resolve" => "connections#create"
    get "/admin/health" => "health#show"
    get "/admin/operations" => "operations#index"
    get "/admin/reconciliation" => "reconciliation#index"
    post "/admin/reconciliation/:mapping_id/authorize-retry" => "reconciliation#authorize_retry"
    post "/admin/reconciliation/:mapping_id/revoke-retry" => "reconciliation#revoke_retry"
  end

  Discourse::Application.routes.append do
    mount ::DiscussionBridge::Engine, at: "/discussion-bridge"
    get "/admin/plugins/discourse-discussion-bridge" => "admin/plugins#index",
        constraints: StaffConstraint.new
    get "/admin/plugins/discourse-discussion-bridge/*path" => "admin/plugins#index",
        constraints: StaffConstraint.new
  end
end
