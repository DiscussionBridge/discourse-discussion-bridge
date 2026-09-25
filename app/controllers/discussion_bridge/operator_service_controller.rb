# frozen_string_literal: true

module DiscussionBridge
  class OperatorServiceController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def show
      render json: payload(service)
    end

    def update
      requested_enabled = boolean_param(params.require(:operator_service).fetch(:enabled))
      requested_enabled ? enable_service : disable_service
      render json: payload(service.reload)
    rescue ArgumentError => error
      render json: { errors: [error.message] }, status: :unprocessable_entity
    end

    def request_service
      service.request!(user: current_user)
      DiscussionBridge::OperatorAudit.record(
        event_type: "service_requested",
        actor: current_user,
        details: { provider_id: service.provider_id, status: service.effective_status },
      )
      enqueue_notification("requested")
      render json: payload(service.reload)
    rescue ArgumentError => error
      render json: { errors: [error.message] }, status: :unprocessable_entity
    end

    def select_provider
      previous_provider_id = service.provider_id
      service.select_provider!(params.require(:operator_service).fetch(:provider_id))
      DiscussionBridge::OperatorAudit.record(
        event_type: "service_provider_selected",
        actor: current_user,
        details: {
          previous_provider_id: previous_provider_id,
          provider_id: service.provider_id,
          status: service.effective_status,
        },
      )
      render json: payload(service.reload)
    rescue ActionController::ParameterMissing, ArgumentError => error
      render json: { errors: [error.message] }, status: :unprocessable_entity
    end

    private

    def service
      @service ||= DiscussionBridgeOperatorService.instance
    end

    def enable_service
      return if service.enabled?

      service.enable!
      DiscussionBridge::OperatorAudit.record(
        event_type: "service_enabled",
        actor: current_user,
        details: { provider_id: service.provider_id, status: service.effective_status },
      )
    end

    def disable_service
      return unless service.enabled?

      notify_service = service.requested_at.present? || service.entitlement_id.present?
      service.disable!
      DiscussionBridge::OperatorAudit.record(
        event_type: "service_disabled",
        actor: current_user,
        details: { provider_id: service.provider_id, status: service.effective_status },
      )
      if notify_service
        service.update!(notification_state: "queued", notification_error: nil)
        enqueue_notification("disabled")
      end
    end

    def enqueue_notification(event)
      Jobs.enqueue(
        :discussion_bridge_operator_service_notification,
        service_id: service.id,
        requested_by_id: current_user.id,
        event: event,
      )
    end

    def payload(record)
      effective_status = record.effective_status
      provider = DiscussionBridge::OperatorProviderRegistry.fetch(record.provider_id)
      {
        enabled: record.enabled,
        status: effective_status,
        selected_provider_id: record.provider_id,
        selected_provider_name: provider[:display_name],
        selected_provider_organization: provider[:organization_name],
        provider_locked: record.provider_locked?,
        providers: DiscussionBridge::OperatorProviderRegistry.public_catalog(
          selected_provider_id: record.provider_id,
        ),
        partner_program: DiscussionBridge::OperatorProviderRegistry::PARTNER_PROGRAM,
        installation_id: record.installation_id,
        enrollment_id: record.enrollment_id,
        service_request_email: provider[:service_request_email],
        grace_period_days: DiscussionBridgeOperatorService::GRACE_PERIOD_DAYS,
        requested_at: record.requested_at,
        requested_by: record.requested_by&.username,
        notification_state: record.notification_state,
        notification_sent_at: record.notification_sent_at,
        request_available: record.request_available?,
        request_submitted: record.requested_at.present?,
        operator_identity_id: record.operator_identity_id,
        operator_email: record.operator_email,
        operator_username: record.operator_user&.username,
        operator_account_ready: record.operator_matches?(record.operator_user),
        identity_version: record.identity_version,
        entitlement_version: record.entitlement_version,
        plan_id: record.plan_id,
        paid_through_at: record.paid_through_at,
        grace_expires_at: record.grace_expires_at,
        operator_can_view: record.view_allowed?(record.operator_user),
        operator_can_mutate: record.mutation_allowed?(record.operator_user),
      }
    end

    def boolean_param(value)
      return true if value == true || value == "true"
      return false if value == false || value == "false"

      raise ArgumentError, "operator service enabled value is invalid"
    end
  end
end
