# frozen_string_literal: true

# name: discourse-discussion-bridge
# about: Forum-governed control plane for DiscussionBridge connections.
# meta_topic_id: 0
# version: 0.1.0.alpha.6
# authors: DiscussionBridge
# url: https://discussionbridge.dev/
# required_version: 3.3.0

require_relative "lib/discussion_bridge/settings_validators"

enabled_site_setting :discussion_bridge_enabled
register_asset "stylesheets/common/discussion-bridge-comments-only.scss"
register_asset "stylesheets/common/discussion-bridge-admin-health.scss"

register_html_builder("server:before-head-close") do |controller|
  next unless defined?(DiscussionBridge::EmbedRouteAttestation)
  next unless SiteSetting.discussion_bridge_enabled
  next unless SiteSetting.discussion_bridge_comments_only_full_interactive
  next unless SiteSetting.embed_full_app
  next unless SiteSetting.embed_full_app_signin_flow
  next unless controller.params[:embed_mode].to_s == "true"

  topic = controller.instance_variable_get(:@topic_view)&.topic
  attestation =
    DiscussionBridge::EmbedRouteAttestation.verify(
      controller.params[:discussion_bridge_embed_token],
    )
  next unless topic && attestation
  next unless attestation[:mapping].topic_id == topic.id
  next unless controller.params[:class_name].to_s == attestation[:class_name]

  %(<meta name="discussion-bridge-completed-mapping" content="#{topic.id}">)
end

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
  require_relative "lib/discussion_bridge/embed_route_attestation"
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

        mapped_full_app =
          params[:full_app].present? && CommentsOnlyPresenter.requested_for?(topic_id: topic_id)

        if mapped_full_app
          unless params[:topic_id].present? || EmbeddableHost.url_allowed?(params[:embed_url])
            raise Discourse::InvalidAccess.new("invalid embed host")
          end

          unless SiteSetting.embed_full_app
            render plain: I18n.t("discussion_bridge.full_interactive_requires_core_full_app"),
                   status: :service_unavailable
            return
          end

          topic = Topic.find_by(id: topic_id)
          raise Discourse::NotFound if topic.blank? || !guardian.can_see?(topic)

          bridge_class = CommentsOnlyPresenter.redirect_class_name(
            topic_id: topic_id,
            full_app: true,
            existing_class_name: params[:class_name],
          )
          mapping = DiscussionBridgeConnection.find_by!(topic_id: topic.id, state: "complete")
          token = EmbedRouteAttestation.issue(mapping: mapping, class_name: bridge_class)
          query = {
            embed_mode: true,
            class_name: bridge_class,
            discussion_bridge_embed_token: token,
          }
          response.headers["X-Robots-Tag"] = "noindex, indexifembedded"
          response.headers["Cache-Control"] = "no-store"
          redirect_to "#{topic.url}?#{query.to_query}"
          return
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
