# frozen_string_literal: true

require "digest"
require "time"

module DiscussionBridge
  class OperatorServiceController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def show
      render json: payload
    end

    def update
      input = params.require(:operator_service)
      reject_unknown_keys!(input, %w[provider_id operator_username enabled])
      enrollment.with_lock do
        if input.key?(:provider_id)
          raise ArgumentError, "operator provider is locked by an entitlement" if enrollment.current_entitlement_id.present?

          provider = DiscussionBridge::OperatorProviderRegistry.fetch(input.fetch(:provider_id))
          enrollment.update!(provider_id: provider.fetch(:id), provider_name: provider.fetch(:name))
        end
        if input.key?(:operator_username)
          user = User.find_by_username(input.fetch(:operator_username).to_s)
          enrollment.bind_operator_user!(user)
        end
        if input.key?(:enabled)
          boolean_param(input.fetch(:enabled)) ? enrollment.enable! : enrollment.disable!
        end
        audit_admin_change("update_operator_service", input.to_unsafe_h)
      end
      render json: payload
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, ArgumentError => error
      render_error(error)
    end

    def enroll_key
      input = params.require(:trusted_key)
      reject_unknown_keys!(input, %w[issuer_id key_id public_key_base64url retire_at])
      attributes = {
        issuer_id: input.fetch(:issuer_id),
        key_id: input.fetch(:key_id),
        public_key_base64url: input.fetch(:public_key_base64url),
        may_issue: true,
        retire_at: input[:retire_at].presence && Time.iso8601(input[:retire_at]),
        enrolled_by: current_user,
        enrolled_at: Time.zone.now,
      }
      DiscussionBridgeOperatorTrustedKey.transaction do
        key = DiscussionBridgeOperatorTrustedKey.create!(attributes)
        operation_sha256 = digest(
          {
            issuer_id: key.issuer_id,
            key_id: key.key_id,
            public_key_base64url: key.public_key_base64url,
            may_issue: key.may_issue?,
            retire_at: key.retire_at&.utc&.iso8601,
          },
        )
        DiscussionBridge::OperatorAudit.record!(
          enrollment: enrollment,
          actor: DiscussionBridge::OperatorAudit.actor(current_user),
          scope: "provider_enrollment",
          action: "enroll_trusted_key",
          target_type: "operator_trusted_key",
          target_id: "#{key.issuer_id}:#{key.key_id}",
          operation_sha256: operation_sha256,
          customer_approval_id: "trusted-key:#{key.id}",
          outcome: "approved",
        )
      end
      render json: payload
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, ArgumentError => error
      render_error(error)
    end

    def revoke_key
      DiscussionBridgeOperatorTrustedKey.transaction do
        key = DiscussionBridgeOperatorTrustedKey.lock.find(params[:id])
        key.update!(may_issue: false, revoked_at: Time.zone.now)
        entitlement = enrollment.current_entitlement
        if entitlement&.issuer_id == key.issuer_id && entitlement.key_id == key.key_id
          enrollment.revoke_current!(actor: current_user)
        end
        DiscussionBridge::OperatorAudit.record!(
          enrollment: enrollment,
          entitlement: entitlement,
          actor: DiscussionBridge::OperatorAudit.actor(current_user),
          scope: "provider_enrollment",
          action: "revoke_trusted_key",
          target_type: "operator_trusted_key",
          target_id: "#{key.issuer_id}:#{key.key_id}",
          operation_sha256: digest({ issuer_id: key.issuer_id, key_id: key.key_id }),
          customer_approval_id: "trusted-key-revocation:#{key.id}",
          outcome: "revoked",
        )
      end
      render json: payload
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, ArgumentError => error
      render_error(error)
    end

    def enroll_entitlement
      DiscussionBridgeOperatorEntitlement.transaction do
        entitlement = DiscussionBridge::OperatorEntitlementVerifier.call(
          payload: params.require(:entitlement).to_unsafe_h,
          enrollment: enrollment,
          actor: current_user,
        )
        enrollment.activate!(entitlement: entitlement, actor: current_user)
      end
      render json: payload
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid,
           DiscussionBridge::OperatorEntitlementVerifier::VerificationError => error
      render_error(error)
    end

    def revoke_entitlement
      enrollment.revoke_current!(actor: current_user)
      render json: payload
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render_error(error)
    end

    def create_approval
      input = params.require(:approval)
      reject_unknown_keys!(input, %w[approval_id scope operation_sha256 expires_at])
      entitlement = enrollment.current_entitlement
      raise ArgumentError, "operator entitlement is unavailable" unless entitlement
      scope = input.fetch(:scope)
      raise ArgumentError, "operator approval scope is not granted by the current entitlement" unless
        entitlement.scope_allowed?(scope)

      DiscussionBridgeOperatorApproval.transaction do
        approval = DiscussionBridgeOperatorApproval.create!(
          approval_id: input.fetch(:approval_id),
          forum_id: enrollment.forum_id,
          provider_id: enrollment.provider_id,
          entitlement_id: entitlement.entitlement_id,
          scope: scope,
          operation_sha256: input.fetch(:operation_sha256),
          approved_by: current_user,
          expires_at: Time.iso8601(input.fetch(:expires_at)),
        )
        DiscussionBridge::OperatorAudit.record!(
          enrollment: enrollment,
          entitlement: entitlement,
          actor: DiscussionBridge::OperatorAudit.actor(current_user),
          scope: approval.scope,
          action: "approve_operation",
          target_type: "operator_approval",
          target_id: approval.approval_id,
          operation_sha256: approval.operation_sha256,
          customer_approval_id: approval.approval_id,
          outcome: "approved",
        )
      end
      render json: payload
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, ArgumentError => error
      render_error(error)
    end

    def audits
      records = DiscussionBridgeOperatorAuditRecord.order(occurred_at: :desc, id: :desc).limit(100)
      render json: { audit_records: records.map(&:contract_payload) }
    end

    private

    def enrollment
      @enrollment ||= DiscussionBridgeOperatorEnrollment.instance
    end

    def payload
      entitlement = enrollment.current_entitlement
      {
        enabled: enrollment.enabled?,
        forum_id: enrollment.forum_id,
        state: enrollment.effective_state,
        provider_id: enrollment.provider_id,
        provider_name: enrollment.provider_name,
        providers: DiscussionBridge::OperatorProviderRegistry.catalog(
          selected_provider_id: enrollment.provider_id,
        ),
        partner_program: DiscussionBridge::OperatorProviderRegistry::PARTNER_PROGRAM,
        operator_username: enrollment.operator_user&.username,
        entitlement: entitlement && {
          entitlement_id: entitlement.entitlement_id,
          issuer_id: entitlement.issuer_id,
          key_id: entitlement.key_id,
          scopes: entitlement.scopes,
          state: entitlement.effective_state,
          issued_at: entitlement.issued_at,
          not_before: entitlement.not_before,
          expires_at: entitlement.expires_at,
          grace_until: entitlement.grace_until,
        },
        trusted_keys: DiscussionBridgeOperatorTrustedKey.order(:issuer_id, :key_id).map do |key|
          {
            id: key.id,
            issuer_id: key.issuer_id,
            key_id: key.key_id,
            may_issue: key.may_issue?,
            retire_at: key.retire_at,
            revoked_at: key.revoked_at,
          }
        end,
      }
    end

    def audit_admin_change(action, value)
      DiscussionBridge::OperatorAudit.record!(
        enrollment: enrollment,
        entitlement: enrollment.current_entitlement,
        actor: DiscussionBridge::OperatorAudit.actor(current_user),
        scope: "provider_enrollment",
        action: action,
        target_type: "operator_enrollment",
        target_id: enrollment.forum_id,
        operation_sha256: digest(value),
        customer_approval_id: "admin-change:#{SecureRandom.hex(8)}",
        outcome: "approved",
      )
    end

    def digest(value)
      Digest::SHA256.hexdigest(DiscussionBridge::OperatorCanonicalJson.generate(value.deep_stringify_keys))
    end

    def boolean_param(value)
      return true if value == true || value == "true"
      return false if value == false || value == "false"

      raise ArgumentError, "operator service enabled value is invalid"
    end

    def reject_unknown_keys!(input, allowed)
      unknown = input.keys.map(&:to_s) - allowed
      raise ArgumentError, "operator service request contains unknown fields" if unknown.any?
    end

    def render_error(error)
      code = error.respond_to?(:code) ? error.code : "validation_failed"
      render json: { error_code: code, message: error.message }, status: :unprocessable_entity
    end
  end
end
