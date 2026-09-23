# frozen_string_literal: true

module DiscussionBridge
  class OperatorEntitlementsController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token

    def update
      service = DiscussionBridgeOperatorService.instance
      raise Discourse::NotFound unless service.enabled?

      RateLimiter.new(nil, "discussion-bridge-operator-entitlement-#{request.remote_ip}", 10, 1.minute).performed!
      input = params.require(:entitlement)
      claims = DiscussionBridge::OperatorEntitlementVerifier.call(
        payload: input.require(:payload).to_unsafe_h,
        signature: input.require(:signature),
        service: service,
      )
      previous_identity = service.operator_identity_id
      service.apply_entitlement!(claims)
      DiscussionBridge::OperatorAudit.record(
        event_type: "entitlement_applied",
        details: {
          entitlement_id: service.entitlement_id,
          entitlement_version: service.entitlement_version,
          identity_version: service.identity_version,
          operator_identity_id: service.operator_identity_id,
          previous_identity_id: previous_identity,
          status: service.effective_status,
        },
      )
      notify_administrators(service, previous_identity: previous_identity)
      render json: {
        outcome: "accepted",
        status: service.effective_status,
        operator_account_ready: service.operator_matches?(service.operator_user),
        identity_version: service.identity_version,
        entitlement_version: service.entitlement_version,
      }
    rescue ActionController::ParameterMissing, ArgumentError => error
      render json: { errors: [error.message] }, status: :unprocessable_entity
    end

    private

    def notify_administrators(service, previous_identity:)
      title = previous_identity.present? && previous_identity != service.operator_identity_id ?
        "discussion_bridge.notification.operator_identity_changed_title" :
        "discussion_bridge.notification.operator_entitlement_updated_title"
      User.where(admin: true, active: true, staged: false).find_each do |admin|
        Notification.create!(
          notification_type: Notification.types[:custom],
          user_id: admin.id,
          data: {
            display_username: "DiscussionBridge",
            message: "success",
            title: title,
            topic_title: "DiscussionBridge Operator service: #{service.effective_status.tr('_', ' ')}",
          }.to_json,
        )
      end
      if service.operator_matches?(service.operator_user)
        Notification.create!(
          notification_type: Notification.types[:custom],
          user_id: service.operator_user_id,
          data: {
            display_username: "DiscussionBridge",
            message: "success",
            title: "discussion_bridge.notification.operator_entitlement_updated_title",
            topic_title: "DiscussionBridge Operator service: #{service.effective_status.tr('_', ' ')}",
            url: "/discussion-bridge-operator",
          }.to_json,
        )
      end
    end
  end
end
