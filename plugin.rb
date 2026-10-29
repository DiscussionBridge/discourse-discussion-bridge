# frozen_string_literal: true

# name: discourse-discussion-bridge
# about: Forum-governed companion discussions for publishing pages.
# meta_topic_id: 0
# version: 0.4.0-alpha.1
# authors: DiscussionBridge
# url: https://discussionbridge.dev/
# required_version: 3.3.0

require_relative "lib/discussion_bridge/settings_validators"
require_relative "lib/discussion_bridge/cms_json_transport_guard"
Rails.application.config.middleware.insert_before(0, DiscussionBridge::CmsJsonTransportGuard)

enabled_site_setting :discussion_bridge_enabled
register_svg_icon "triangle-exclamation"
register_asset "stylesheets/common/discussion-bridge-comments-only.scss"
register_asset "stylesheets/common/discussion-bridge-admin-health.scss"
register_asset "stylesheets/common/discussion-bridge-publishing.scss"

register_html_builder("server:before-head-close") do |controller|
  next unless defined?(DiscussionBridge::EmbedRouteAttestation)
  next unless DiscussionBridge::InteractiveReadiness.ready?
  next unless controller.params[:embed_mode].to_s == "true"

  topic = controller.instance_variable_get(:@topic_view)&.topic
  attestation =
    DiscussionBridge::EmbedRouteAttestation.verify(
      controller.params[:discussion_bridge_embed_token],
    )
  next unless topic && attestation
  next unless attestation[:mapping].topic_id == topic.id
  next unless controller.params[:class_name].to_s == attestation[:class_name]
  integrity =
    DiscussionBridge::ExistingMappingIntegrity.current(
      mapping_id: attestation[:mapping].id,
      expected_topic_id: topic.id,
      expected_updated_at: attestation[:mapping].updated_at,
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
Rails.application.config.filter_parameters << /lease_token/i

after_initialize do
  module ::DiscussionBridge
    PLUGIN_NAME = "discourse-discussion-bridge"
    VERSION = "0.4.0-alpha.1"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscussionBridge
    end
  end

  require_relative "lib/discussion_bridge/canonical_source"
  require_relative "lib/discussion_bridge/native_constraints"
  require_relative "lib/discussion_bridge/managed_native_publication"
  require_relative "lib/discussion_bridge/site_setting_label_formatter_extension"
  require_relative "lib/discussion_bridge/lane_policies"
  require_relative "lib/discussion_bridge/policy_evaluator"
  require_relative "lib/discussion_bridge/forum_authority"
  require_relative "lib/discussion_bridge/bridge_reconciliation_index"
  require_relative "lib/discussion_bridge/audit_state"
  require_relative "lib/discussion_bridge/existing_mapping_integrity"
  require_relative "lib/discussion_bridge/portable_content"
  require_relative "lib/discussion_bridge/native_content_preservation"
  require_relative "lib/discussion_bridge/topic_creator"
  require_relative "lib/discussion_bridge/interactive_readiness"
  require_relative "lib/discussion_bridge/comments_only_presenter"
  require_relative "lib/discussion_bridge/embed_route_attestation"
  require_relative "lib/discussion_bridge/forum_name"
  require_relative "lib/discussion_bridge/source_edition"
  require_relative "lib/discussion_bridge/cms_protocol"
  require_relative "lib/discussion_bridge/cms_generated_excerpt"
  require_relative "lib/discussion_bridge/cms_configuration"
  require_relative "lib/discussion_bridge/cms_receipt_cipher"
  require_relative "lib/discussion_bridge/cms_work_coordinator"
  require_relative "lib/discussion_bridge/cms_attention_evidence"
  require_relative "lib/discussion_bridge/cms_attention_recovery"
  require_relative "lib/discussion_bridge/cms_attention_notifications"
  require_relative "lib/discussion_bridge/cms_source_store"
  require_relative "lib/discussion_bridge/cms_authority_store"
  require_relative "lib/discussion_bridge/cms_mapping_projection"
  require_relative "lib/discussion_bridge/cms_delivery_projection"
  require_relative "lib/discussion_bridge/cms_url_reservation"
  require_relative "lib/discussion_bridge/cms_mapping_service"
  require_relative "lib/discussion_bridge/cms_mapping_read_store"
  require_relative "lib/discussion_bridge/cms_to_publication"
  require_relative "lib/discussion_bridge/cms_record_store"
  require_relative "lib/discussion_bridge/cms_record_read_store"
  require_relative "lib/discussion_bridge/cms_move_reservation"
  require_relative "lib/discussion_bridge/cms_url_move_proof"
  require_relative "lib/discussion_bridge/cms_presentation_move_store"
  require_relative "lib/discussion_bridge/cms_source_move_store"
  require_relative "lib/discussion_bridge/cms_source_lifecycle"
  require_relative "lib/discussion_bridge/cms_catalog_store"
  require_relative "lib/discussion_bridge/cms_admin_inspection_store"
  require_relative "lib/discussion_bridge/cms_catalog_availability_lifecycle"
  require_relative "lib/discussion_bridge/cms_authority_lifecycle"
  require_relative "lib/discussion_bridge/cms_native_observer"
  require_relative "lib/discussion_bridge/cms_global_gate_observer"
  require_relative "lib/discussion_bridge/source_authorship"
  require_relative "lib/discussion_bridge/bridge_record_resolver"
  require_relative "lib/discussion_bridge/from_discourse_record_creator"
  require_relative "lib/discussion_bridge/presentation_binding_corrector"
  require_relative "lib/discussion_bridge/product_overview"
  require_relative "lib/discussion_bridge/support_topic_selection"
  require_relative "lib/discussion_bridge/support_access"
  require_relative "lib/discussion_bridge/support_workflow"
  require_relative "lib/discussion_bridge/support_operations"
  require_relative "lib/discussion_bridge/support_controller_input"
  require_relative "app/models/discussion_bridge_support_state"
  require_relative "app/models/discussion_bridge_support_grant"
  require_relative "app/models/discussion_bridge_support_request"
  require_relative "app/mailers/discussion_bridge/support_mailer"
  require_relative "app/models/discussion_bridge_audit_event"
  require_relative "app/models/discussion_bridge_content_connection"
  require_relative "app/models/discussion_bridge_source_author"
  require_relative "app/models/discussion_bridge_bridge_record"
  require_relative "app/models/discussion_bridge_content_binding"
  require_relative "app/models/discussion_bridge_cms_mapping"
  require_relative "app/models/discussion_bridge_cms_work"
  require_relative "app/models/discussion_bridge_cms_attention_inspection"
  require_relative "app/models/discussion_bridge_cms_attention_recovery"
  require_relative "app/models/discussion_bridge_cms_attention_notice"
  require_relative "app/models/discussion_bridge_cms_attention_delivery"
  require_relative "app/models/discussion_bridge_cms_to_source_revision"
  require_relative "app/models/discussion_bridge_cms_url_move"
  require_relative "app/models/discussion_bridge_cms_mutation_receipt"
  require_relative "app/models/discussion_bridge_cms_source_stream"
  require_relative "app/models/discussion_bridge_cms_source_intent"
  require_relative "app/models/discussion_bridge_cms_source_revision"
  require_relative "app/models/discussion_bridge_cms_source_event"
  require_relative "app/models/discussion_bridge_cms_source_cursor"
  require_relative "app/models/discussion_bridge_cms_source_snapshot_item"
  require_relative "app/models/discussion_bridge_cms_url_reservation"
  require_relative "app/models/discussion_bridge_cms_url_history_entry"
  require_relative "app/models/discussion_bridge_cms_read_snapshot"
  require_relative "app/models/discussion_bridge_cms_read_snapshot_item"
  require_relative "app/models/discussion_bridge_cms_read_cursor"
  require_relative "app/models/discussion_bridge_cms_catalog_upload"
  require_relative "app/models/discussion_bridge_cms_catalog_page"
  require_relative "app/models/discussion_bridge_cms_catalog_entry"
  require_relative "app/models/discussion_bridge_cms_catalog_snapshot"
  require_relative "app/models/discussion_bridge_cms_catalog_cursor"
  require_relative "app/models/discussion_bridge_cms_scope_event"
  require_relative "app/controllers/discussion_bridge/admin_content_connections_controller"
  require_relative "app/controllers/discussion_bridge/admin_bridge_records_controller"
  require_relative "app/controllers/discussion_bridge/health_controller"
  require_relative "app/controllers/discussion_bridge/support_admin_controller"
  require_relative "app/controllers/discussion_bridge/support_workspace_controller"
  require_relative "app/controllers/discussion_bridge/reconciliation_controller"
  require_relative "app/controllers/discussion_bridge/publisher_controller"
  require_relative "app/controllers/discussion_bridge/cms_work_controller"
  require_relative "app/controllers/discussion_bridge/cms_attention_controller"
  require_relative "app/controllers/discussion_bridge/cms_admin_attention_controller"
  require_relative "app/controllers/discussion_bridge/cms_sources_controller"
  require_relative "app/controllers/discussion_bridge/cms_connection_controller"
  require_relative "app/controllers/discussion_bridge/cms_admin_configuration_controller"
  require_relative "app/controllers/discussion_bridge/cms_admin_delivery_controller"
  require_relative "app/controllers/discussion_bridge/cms_admin_inspection_controller"
  require_relative "app/controllers/discussion_bridge/cms_mappings_controller"
  require_relative "app/controllers/discussion_bridge/cms_records_controller"
  require_relative "app/controllers/discussion_bridge/cms_presentation_moves_controller"
  require_relative "app/controllers/discussion_bridge/cms_source_moves_controller"
  require_relative "app/controllers/discussion_bridge/cms_catalog_controller"
  require_relative "jobs/regular/discussion_bridge_cms_source_batch"
  require_relative "jobs/regular/discussion_bridge_cms_attention_notifications"
  require_relative "jobs/regular/discussion_bridge_support_request"
  require_relative "jobs/scheduled/discussion_bridge_cms_lifecycle_maintenance"
  DiscussionBridge::CmsAuthorityLifecycle.catalog_invalidator = ->(connection, clock:) do
    DiscussionBridge::CmsCatalogStore.invalidate_scope!(connection, clock: clock)
  end
  DiscussionBridge::CmsNativeObserver.register(self)
  # This observer must also see the plugin's disable event. Plugin::Instance#on
  # intentionally filters disabled plugins, so use the native event here.
  # rubocop:disable Discourse/Plugins/UsePluginInstanceOn
  DiscourseEvent.on(:site_setting_changed) do |name, previous, current|
    DiscussionBridge::CmsGlobalGateObserver.changed(name, previous, current)
  end
  # rubocop:enable Discourse/Plugins/UsePluginInstanceOn
  unless SiteSettings::LabelFormatter.singleton_class <
           DiscussionBridge::SiteSettingLabelFormatterExtension
    SiteSettings::LabelFormatter.singleton_class.prepend(
      DiscussionBridge::SiteSettingLabelFormatterExtension,
    )
  end

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
        source_presentation =
          CommentsOnlyPresenter.source_presentation_requested?(params[:class_name]) &&
            CommentsOnlyPresenter.source_presentation_topic?(topic_id: topic_id)
        protected_topic = mapped_topic || source_presentation
        full_app_supplied = params.key?(:full_app)
        full_app_requested = params[:full_app].is_a?(String) && params[:full_app] == "true"

        if protected_topic && full_app_supplied && !full_app_requested
          render plain: I18n.t("discussion_bridge.interactive_invalid_request"),
                 status: :unprocessable_entity
          return
        end

        mapped_full_app = protected_topic && full_app_requested

        if mapped_full_app
          unless CommentsOnlyPresenter.valid_existing_class_name?(params[:class_name])
            render plain: I18n.t("discussion_bridge.interactive_invalid_class"),
                   status: :unprocessable_entity
            return
          end

          unless params[:topic_id].present? || EmbeddableHost.url_allowed?(params[:embed_url])
            raise Discourse::InvalidAccess.new("invalid embed host")
          end

          blockers = InteractiveReadiness.blockers
          if blockers.any?
            render plain:
                     I18n.t(
                       "discussion_bridge.interactive_unavailable",
                       reasons: blockers.join(", "),
                     ),
                   status: :service_unavailable
            return
          end

          mapping =
            if source_presentation
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
              )
            end
          unless mapping
            render plain:
                     I18n.t(
                       "discussion_bridge.interactive_unavailable",
                       reasons: "mapping_changed",
                     ),
                   status: :service_unavailable
            return
          end
          integrity =
            ExistingMappingIntegrity.current(
              mapping_id: mapping.id,
              expected_topic_id: topic_id.to_i,
              expected_updated_at: mapping.updated_at,
            )
          unless integrity.usable? && guardian.can_see?(integrity.topic)
            render plain:
                     I18n.t(
                       "discussion_bridge.interactive_unavailable",
                       reasons: integrity.reason || "topic_denied",
                     ),
                   status: :service_unavailable
            return
          end
          topic = integrity.topic

          bridge_class =
            CommentsOnlyPresenter.redirect_class_name(
              topic_id: topic_id,
              full_app: true,
              existing_class_name: params[:class_name],
            )
          unless CommentsOnlyPresenter.valid_final_class_name?(bridge_class)
            render plain: I18n.t("discussion_bridge.interactive_invalid_class"),
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
          bridge_class =
            CommentsOnlyPresenter.redirect_class_name(
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
        protected_topic =
          CommentsOnlyPresenter.mapped_topic?(topic_id: topic_id) ||
            (
              CommentsOnlyPresenter.source_presentation_requested?(params[:class_name]) &&
                CommentsOnlyPresenter.source_presentation_topic?(topic_id: topic_id)
            )
        return unless protected_topic
        return unless params.key?(:full_app)

        unless params[:full_app].is_a?(String) && params[:full_app] == "true"
          render plain: I18n.t("discussion_bridge.interactive_invalid_request"),
                 status: :unprocessable_entity
          return
        end
        return if CommentsOnlyPresenter.valid_existing_class_name?(params[:class_name])

        render plain: I18n.t("discussion_bridge.interactive_invalid_class"),
               status: :unprocessable_entity
      end
    end
  end

  unless EmbedController < DiscussionBridge::EmbedControllerExtension
    EmbedController.prepend(DiscussionBridge::EmbedControllerExtension)
  end

  module ::DiscussionBridge
    module TopicControllerInteractiveGuard
      def show
        guard_discussion_bridge_interactive_destination
        return if performed?

        super
      end

      private

      def guard_discussion_bridge_interactive_destination
        token = params[:discussion_bridge_embed_token]
        payload = EmbedRouteAttestation.authenticated_payload(token)
        return unless payload

        requested_topic_id = Integer(params[:topic_id] || params[:id], exception: false)
        return unless requested_topic_id == payload["topic_id"]

        attestation = EmbedRouteAttestation.verify(token)
        class_name = params[:class_name].to_s
        integrity =
          attestation &&
            ExistingMappingIntegrity.current(
              mapping_id: attestation[:mapping].id,
              expected_topic_id: requested_topic_id,
              expected_updated_at: attestation[:mapping].updated_at,
            )
        valid =
          InteractiveReadiness.ready? && params[:embed_mode].to_s == "true" && attestation &&
            attestation[:mapping].topic_id == requested_topic_id &&
            class_name == attestation[:class_name] && integrity&.usable? &&
            guardian.can_see?(integrity.topic)
        return if valid

        render plain:
                 I18n.t(
                   "discussion_bridge.interactive_unavailable",
                   reasons: "stale_or_unready_route",
                 ),
               status: :service_unavailable
      end
    end
  end

  unless TopicsController < DiscussionBridge::TopicControllerInteractiveGuard
    TopicsController.prepend(DiscussionBridge::TopicControllerInteractiveGuard)
  end

  DiscussionBridge::Engine.routes.draw do
    get "/v4/connection" => "cms_connection#show"
    post "/v4/bridge-records/resolve" => "cms_records#resolve"
    get "/v4/bridge-records" => "cms_records#index"
    get "/v4/bridge-records/:resource_id" => "cms_records#show"
    post "/v4/bridge-records/:resource_id/withdraw" => "cms_records#withdraw"
    get "/v4/sources" => "cms_sources#index"
    get "/v4/sources/:source_id/revisions/:source_revision/content" => "cms_sources#content"
    get "/v4/policy" => "cms_connection#policy"
    post "/v4/mappings/prepare" => "cms_mappings#prepare"
    get "/v4/mappings" => "cms_mappings#index"
    get "/v4/mappings/:mapping_id" => "cms_mappings#show"
    get "/v4/mappings/:mapping_id/url-history" => "cms_mappings#url_history"
    post "/v4/work/claim" => "cms_work#claim"
    get "/v4/work/recoveries" => "cms_attention#recoveries"
    get "/v4/work/:work_id" => "cms_work#show"
    post "/v4/work/:work_id/renew" => "cms_work#renew"
    post "/v4/work/:work_id/acknowledge" => "cms_work#acknowledge"
    post "/v4/work/:work_id/fail" => "cms_work#fail"
    post "/v4/work/:work_id/prepare" => "cms_work#prepare"
    post "/v4/work/:work_id/finalize" => "cms_work#finalize"
    post "/v4/work/:work_id/abort" => "cms_work#abort"
    post "/v4/mappings/:mapping_id/url-moves" => "cms_presentation_moves#prepare"
    post "/v4/mappings/:mapping_id/url-moves/:move_id/finalize" => "cms_presentation_moves#finalize"
    post "/v4/mappings/:mapping_id/url-moves/:move_id/abort" => "cms_presentation_moves#abort"
    post "/v4/catalog/uploads" => "cms_catalog#begin_upload"
    post "/v4/catalog/uploads/:upload_id/pages" => "cms_catalog#append_page"
    post "/v4/catalog/uploads/:upload_id/finalize" => "cms_catalog#finalize"
    get "/v4/catalog" => "cms_catalog#index"
    post "/v4/bridge-records/:resource_id/source-url-moves" => "cms_source_moves#prepare"
    post "/v4/bridge-records/:resource_id/source-url-moves/:move_id/finalize" => "cms_source_moves#finalize"
    post "/v4/bridge-records/:resource_id/source-url-moves/:move_id/abort" => "cms_source_moves#abort"
    get "/v4/bridge-records/:resource_id/url-history" => "cms_source_moves#url_history"
    get "/v4/attention-recovery" => "cms_attention#capability"
    get "/v4/attention-inspections" => "cms_attention#inspections"
    post "/v4/attention-inspections/:inspection_id/report" => "cms_attention#report"
    post "/v4/work/recoveries/:recovery_id/claim" => "cms_attention#recovery_claim"
    get "/admin/health" => "health#show"
    get "/admin/support-bundle" => "health#support_bundle"
    get "/admin/support" => "support_admin#show"
    put "/admin/support" => "support_admin#update"
    post "/admin/support/requests" => "support_admin#request_assistance"
    post "/admin/support/grants" => "support_admin#grant"
    delete "/admin/support/grants/:id" => "support_admin#revoke"
    get "/support/client.js" => "support_workspace#client"
    get "/support" => "support_workspace#show"
    get "/support/workspace" => "support_workspace#show"
    post "/support/connections/:id/check" => "support_workspace#check"
    post "/support/connections/:id/retry" => "support_workspace#retry_selected"
    post "/support/connections/:id/select-topic" => "support_workspace#select_topic"
    post "/support/connections/:id/synchronize" => "support_workspace#synchronize"
    get "/admin/content-connections" => "admin_content_connections#index"
    post "/admin/content-connections" => "admin_content_connections#create"
    put "/admin/content-connections/:id" => "admin_content_connections#update"
    post "/admin/content-connections/:id/rotate-secret" => "admin_content_connections#rotate_secret"
    put "/admin/content-connections/:id/authors/:author_id" => "admin_content_connections#update_author"
    get "/admin/bridge-records" => "admin_bridge_records#index"
    post "/admin/bridge-records" => "admin_bridge_records#create"
    get "/admin/bridge-records/:id" => "admin_bridge_records#show"
    get "/admin/reconciliation" => "reconciliation#index"
    get "/admin/reconciliation/report" => "reconciliation#report"
  end

  Discourse::Application.routes.append do
    mount ::DiscussionBridge::Engine, at: "/discussion-bridge"
    get "/admin/publishing" => "discussion_bridge/publisher#overview"
    post "/admin/publishing/topics/:topic_id/publish" => "discussion_bridge/publisher#publish_topic"
    put "/admin/publishing/publications/:resource_id/presentation" => "discussion_bridge/publisher#correct_presentation"
    get "/admin/publishing/topics/:topic_id/status" => "discussion_bridge/publisher#topic_status"
    get "/admin/content-connections/:id/cms-configuration" => "discussion_bridge/cms_admin_configuration#show"
    put "/admin/content-connections/:id/cms-configuration" => "discussion_bridge/cms_admin_configuration#update"
    get "/admin/content-connections/:id/cms-delivery" => "discussion_bridge/cms_admin_delivery#index"
    post "/admin/content-connections/:id/cms-attention/check" => "discussion_bridge/cms_admin_attention#check"
    post "/admin/content-connections/:id/cms-attention/retry" => "discussion_bridge/cms_admin_attention#retry_selected"
    get "/admin/content-connections/:id/cms-preview" => "discussion_bridge/cms_admin_inspection#preview"
    get "/admin/content-connections/:id/cms-catalog" => "discussion_bridge/cms_admin_inspection#catalog"
    get "/admin/plugins/discourse-discussion-bridge" => "admin/plugins#index", :constraints => StaffConstraint.new
    get "/admin/plugins/discourse-discussion-bridge/*path" => "admin/plugins#index", :constraints => StaffConstraint.new
  end
end
