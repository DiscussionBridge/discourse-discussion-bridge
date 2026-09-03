# frozen_string_literal: true

# name: discourse-discussion-bridge
# about: Forum-governed companion discussions for publishing pages.
# meta_topic_id: 0
# version: 0.2.0.alpha.18
# authors: DiscussionBridge
# url: https://discussionbridge.dev/
# required_version: 3.3.0

require_relative "lib/discussion_bridge/settings_validators"

enabled_site_setting :discussion_bridge_enabled
register_asset "stylesheets/common/discussion-bridge-comments-only.scss"
register_asset "stylesheets/common/discussion-bridge-admin-health.scss"
register_asset "stylesheets/common/discussion-bridge-publishing.scss"

register_html_builder("server:before-head-close") do |controller|
  next unless defined?(DiscussionBridge::EmbedRouteAttestation)
  next unless DiscussionBridge::FullInteractiveReadiness.ready?
  next unless controller.params[:embed_mode].to_s == "true"

  topic = controller.instance_variable_get(:@topic_view)&.topic
  attestation =
    DiscussionBridge::EmbedRouteAttestation.verify(
      controller.params[:discussion_bridge_embed_token],
    )
  next unless topic && attestation
  next unless attestation[:mapping].topic_id == topic.id
  next unless controller.params[:class_name].to_s == attestation[:class_name]
  integrity = DiscussionBridge::ExistingMappingIntegrity.current(
    mapping_id: attestation[:mapping].id,
    expected_topic_id: topic.id,
    expected_updated_at: attestation[:mapping].updated_at,
    record_type: attestation[:mapping].is_a?(DiscussionBridgeBridgeRecord) ? "bridge_record" : "legacy_mapping",
  )
  next unless integrity.usable?

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
    VERSION = "0.2.0.alpha.18"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscussionBridge
    end
  end

  require_relative "lib/discussion_bridge/canonical_source"
  require_relative "lib/discussion_bridge/connection_request"
  require_relative "lib/discussion_bridge/bridge_record_request"
  require_relative "lib/discussion_bridge/site_setting_label_formatter_extension"
  require_relative "lib/discussion_bridge/lane_policies"
  require_relative "lib/discussion_bridge/policy_evaluator"
  require_relative "lib/discussion_bridge/forum_authority"
  require_relative "lib/discussion_bridge/bridge_reconciliation_index"
  require_relative "lib/discussion_bridge/audit_state"
  require_relative "lib/discussion_bridge/existing_mapping_integrity"
  require_relative "lib/discussion_bridge/portable_content"
  require_relative "lib/discussion_bridge/topic_creator"
  require_relative "lib/discussion_bridge/full_interactive_readiness"
  require_relative "lib/discussion_bridge/comments_only_presenter"
  require_relative "lib/discussion_bridge/embed_route_attestation"
  require_relative "lib/discussion_bridge/adapter_feed_snapshot"
  require_relative "lib/discussion_bridge/content_connection_authenticator"
  require_relative "lib/discussion_bridge/source_authorship"
  require_relative "lib/discussion_bridge/bridge_record_resolver"
  require_relative "lib/discussion_bridge/from_discourse_record_creator"
  require_relative "lib/discussion_bridge/product_overview"
  require_relative "app/models/discussion_bridge_connection"
  require_relative "app/models/discussion_bridge_audit_event"
  require_relative "app/models/discussion_bridge_content_connection"
  require_relative "app/models/discussion_bridge_source_author"
  require_relative "app/models/discussion_bridge_bridge_record"
  require_relative "app/models/discussion_bridge_content_binding"
  require_relative "app/controllers/discussion_bridge/adapter_bridge_records_controller"
  require_relative "app/controllers/discussion_bridge/admin_content_connections_controller"
  require_relative "app/controllers/discussion_bridge/admin_bridge_records_controller"
  require_relative "app/controllers/discussion_bridge/health_controller"
  require_relative "app/controllers/discussion_bridge/reconciliation_controller"
  require_relative "app/controllers/discussion_bridge/publisher_controller"

  SiteSettings::LabelFormatter.singleton_class.prepend(
    DiscussionBridge::SiteSettingLabelFormatterExtension,
  ) unless SiteSettings::LabelFormatter.singleton_class <
    DiscussionBridge::SiteSettingLabelFormatterExtension

  module ::DiscussionBridge
    module EmbedControllerExtension
      def self.prepended(base)
        base.prepend_before_action :guard_discussion_bridge_embed_parameters, only: [:comments]
      end

      def comments
        topic_id =
          if params[:topic_id].present?
            params[:topic_id]
          elsif params[:embed_url].present?
            TopicEmbed.topic_id_for_embed(params[:embed_url])
          end

        mapped_topic = CommentsOnlyPresenter.mapped_topic?(topic_id: topic_id)
        source_presentation = CommentsOnlyPresenter.source_presentation_requested?(
          params[:class_name],
        ) && CommentsOnlyPresenter.source_presentation_topic?(topic_id: topic_id)
        protected_topic = mapped_topic || source_presentation
        full_app_supplied = params.key?(:full_app)
        full_app_requested = params[:full_app].is_a?(String) && params[:full_app] == "true"

        if protected_topic && full_app_supplied && !full_app_requested
          render plain: I18n.t("discussion_bridge.full_interactive_invalid_request"),
                 status: :unprocessable_entity
          return
        end

        mapped_full_app = protected_topic && full_app_requested

        if mapped_full_app
          unless CommentsOnlyPresenter.valid_existing_class_name?(params[:class_name])
            render plain: I18n.t("discussion_bridge.full_interactive_invalid_class"),
                   status: :unprocessable_entity
            return
          end

          unless params[:topic_id].present? || EmbeddableHost.url_allowed?(params[:embed_url])
            raise Discourse::InvalidAccess.new("invalid embed host")
          end

          blockers = FullInteractiveReadiness.blockers
          if blockers.any?
            render plain: I18n.t(
                     "discussion_bridge.full_interactive_unavailable",
                     reasons: blockers.join(", "),
                   ),
                   status: :service_unavailable
            return
          end

          mapping = if source_presentation
            DiscussionBridgeBridgeRecord.find_by(
              topic_id: topic_id,
              state: "healthy",
              direction: "from_discourse",
            )
          else
            DiscussionBridgeBridgeRecord.find_by(
              topic_id: topic_id,
              state: "healthy",
              direction: "to_discourse",
            ) ||
              DiscussionBridgeConnection.find_by(topic_id: topic_id, state: "complete")
          end
          unless mapping
            render plain: I18n.t(
                     "discussion_bridge.full_interactive_unavailable",
                     reasons: "mapping_changed",
                   ),
                   status: :service_unavailable
            return
          end
          integrity = ExistingMappingIntegrity.current(
            mapping_id: mapping.id,
            expected_topic_id: topic_id.to_i,
            expected_updated_at: mapping.updated_at,
            record_type: mapping.is_a?(DiscussionBridgeBridgeRecord) ? "bridge_record" : "legacy_mapping",
          )
          unless integrity.usable? && guardian.can_see?(integrity.topic)
            render plain: I18n.t(
                     "discussion_bridge.full_interactive_unavailable",
                     reasons: integrity.reason || "topic_denied",
                   ),
                   status: :service_unavailable
            return
          end
          topic = integrity.topic

          bridge_class = CommentsOnlyPresenter.redirect_class_name(
            topic_id: topic_id,
            full_app: true,
            existing_class_name: params[:class_name],
          )
          unless CommentsOnlyPresenter.valid_final_class_name?(bridge_class)
            render plain: I18n.t("discussion_bridge.full_interactive_invalid_class"),
                   status: :unprocessable_entity
            return
          end
          token = EmbedRouteAttestation.issue(mapping: integrity.mapping, class_name: bridge_class)
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

        if full_app_requested
          bridge_class = CommentsOnlyPresenter.redirect_class_name(
            topic_id: topic_id,
            full_app: true,
            existing_class_name: params[:class_name],
          )
          bridge_class.present? ? params[:class_name] = bridge_class : params.delete(:class_name)
        end

        super
      end

      private

      def guard_discussion_bridge_embed_parameters
        topic_id =
          if params[:topic_id].present?
            params[:topic_id]
          elsif params[:embed_url].present? && EmbeddableHost.url_allowed?(params[:embed_url])
            TopicEmbed.topic_id_for_embed(params[:embed_url])
          end
        protected_topic = CommentsOnlyPresenter.mapped_topic?(topic_id: topic_id) || (
          CommentsOnlyPresenter.source_presentation_requested?(params[:class_name]) &&
            CommentsOnlyPresenter.source_presentation_topic?(topic_id: topic_id)
        )
        return unless protected_topic
        return unless params.key?(:full_app)

        unless params[:full_app].is_a?(String) && params[:full_app] == "true"
          render plain: I18n.t("discussion_bridge.full_interactive_invalid_request"),
                 status: :unprocessable_entity
          return
        end
        return if CommentsOnlyPresenter.valid_existing_class_name?(params[:class_name])

        render plain: I18n.t("discussion_bridge.full_interactive_invalid_class"),
               status: :unprocessable_entity
      end
    end
  end

  EmbedController.prepend(DiscussionBridge::EmbedControllerExtension) unless
    EmbedController < DiscussionBridge::EmbedControllerExtension

  module ::DiscussionBridge
    module TopicControllerFullInteractiveGuard
      def show
        guard_discussion_bridge_full_interactive_destination
        return if performed?

        super
      end

      private

      def guard_discussion_bridge_full_interactive_destination
        token = params[:discussion_bridge_embed_token]
        payload = EmbedRouteAttestation.authenticated_payload(token)
        return unless payload

        requested_topic_id = Integer(params[:topic_id] || params[:id], exception: false)
        return unless requested_topic_id == payload["topic_id"]

        attestation = EmbedRouteAttestation.verify(token)
        class_name = params[:class_name].to_s
        integrity = attestation && ExistingMappingIntegrity.current(
          mapping_id: attestation[:mapping].id,
          expected_topic_id: requested_topic_id,
          expected_updated_at: attestation[:mapping].updated_at,
          record_type: attestation[:mapping].is_a?(DiscussionBridgeBridgeRecord) ? "bridge_record" : "legacy_mapping",
        )
        valid = FullInteractiveReadiness.ready? &&
          params[:embed_mode].to_s == "true" &&
          attestation &&
          attestation[:mapping].topic_id == requested_topic_id &&
          class_name == attestation[:class_name] &&
          integrity&.usable? && guardian.can_see?(integrity.topic)
        return if valid

        render plain: I18n.t(
                 "discussion_bridge.full_interactive_unavailable",
                 reasons: "stale_or_unready_route",
               ),
               status: :service_unavailable
      end

    end
  end

  TopicsController.prepend(DiscussionBridge::TopicControllerFullInteractiveGuard) unless
    TopicsController < DiscussionBridge::TopicControllerFullInteractiveGuard

  DiscussionBridge::Engine.routes.draw do
    post "/v1/bridge-records/resolve" => "adapter_bridge_records#create"
    get "/v1/bridge-records" => "adapter_bridge_records#index"
    get "/v1/bridge-records/:resource_id" => "adapter_bridge_records#show"
    get "/admin/health" => "health#show"
    get "/admin/support-bundle" => "health#support_bundle"
    get "/admin/content-connections" => "admin_content_connections#index"
    post "/admin/content-connections" => "admin_content_connections#create"
    put "/admin/content-connections/:id" => "admin_content_connections#update"
    post "/admin/content-connections/:id/rotate-secret" => "admin_content_connections#rotate_secret"
    put "/admin/content-connections/:id/authors/:author_id" => "admin_content_connections#update_author"
    get "/admin/bridge-records" => "admin_bridge_records#index"
    post "/admin/bridge-records" => "admin_bridge_records#create"
    get "/admin/bridge-records/:id" => "admin_bridge_records#show"
    post "/admin/bridge-records/:id/migrations" => "admin_bridge_records#prepare_migration"
    post "/admin/bridge-records/:id/migrations/:binding_id/apply" => "admin_bridge_records#apply_migration"
    get "/admin/reconciliation" => "reconciliation#index"
    get "/admin/reconciliation/report" => "reconciliation#report"
    get "/admin/publishing" => "publisher#overview"
    post "/v1/publisher/topics/:topic_id/publish" => "publisher#publish_topic"
    get "/v1/publisher/topics/:topic_id/status" => "publisher#topic_status"
  end

  Discourse::Application.routes.append do
    mount ::DiscussionBridge::Engine, at: "/discussion-bridge"
    get "/admin/plugins/discourse-discussion-bridge" => "admin/plugins#index",
        constraints: StaffConstraint.new
    get "/admin/plugins/discourse-discussion-bridge/*path" => "admin/plugins#index",
        constraints: StaffConstraint.new
  end
end
