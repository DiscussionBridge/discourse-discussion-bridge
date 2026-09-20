# frozen_string_literal: true

module DiscussionBridge
  class AdapterPublicationWorkController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_json_request
    before_action :ensure_enabled
    before_action :authenticate_connection
    before_action :ensure_publication_scope

    DEFAULT_LEASE_DURATION = 5.minutes
    MAX_LEASE_DURATION = 1.hour
    MAX_AUTOMATIC_ATTEMPTS = 3

    def claim
      lease_duration = params[:lease_seconds].nil? ? DEFAULT_LEASE_DURATION.to_i : params[:lease_seconds]
      raise ArgumentError, "invalid lease duration" unless
        lease_duration.is_a?(Integer) && lease_duration.between?(DEFAULT_LEASE_DURATION.to_i,
                                                                 MAX_LEASE_DURATION.to_i)
      item = nil
      token = nil
      now = Time.zone.now
      DiscussionBridgePublicationWorkItem.transaction do
        @content_connection.lock!
        @content_connection.publication_work_items
          .where(state: "claimed")
          .where("lease_expires_at <= ?", now)
          .update_all(
            state: "retrying",
            reason: "lease_expired",
            lease_token: nil,
            claimed_at: nil,
            lease_expires_at: nil,
            available_at: now,
            updated_at: now,
          )
        item = @content_connection.publication_work_items
          .where(state: %w[queued retrying])
          .where("available_at IS NULL OR available_at <= ?", now)
          .order(:available_at, :id)
          .lock("FOR UPDATE SKIP LOCKED")
          .first
        if item
          token = SecureRandom.hex(32)
          item.update!(
            state: "claimed",
            lease_token: token,
            claimed_at: now,
            lease_expires_at: now + lease_duration,
            available_at: nil,
            completed_at: nil,
            attempt_count: item.attempt_count + 1,
          )
        end
      end

      if item
        render json: { publication_work: payload(item, token: token) }
      else
        render json: { publication_work: nil }
      end
    rescue ArgumentError => error
      render json: {
        outcome: "rejected",
        reason: error.message == "invalid lease duration" ? "invalid_lease_duration" : "invalid_publication_claim",
        errors: [error.message],
      }, status: :unprocessable_entity
    end

    def fail
      input = params.require(:publication_work_failure)
      token = input.fetch(:lease_token).to_s
      error_code = input.fetch(:error_code).to_s
      error_detail = input[:error_detail].to_s.presence
      raise ArgumentError, "invalid lease token" unless token.match?(/\A[a-f0-9]{64}\z/)
      raise ArgumentError, "invalid error code" unless error_code.match?(/\A[a-z0-9_-]{1,64}\z/)
      raise ArgumentError, "invalid error detail" if error_detail&.bytesize.to_i > 1000

      item = nil
      now = Time.zone.now
      DiscussionBridgePublicationWorkItem.transaction do
        @content_connection.lock!
        item = @content_connection.publication_work_items.lock.find_by!(
          state: "claimed",
          lease_token: token,
        )
        raise ArgumentError, "publication lease expired" unless item.lease_expires_at&.future?

        exhausted = item.attempt_count >= MAX_AUTOMATIC_ATTEMPTS
        item.update!(
          state: exhausted ? "failed" : "retrying",
          reason: "delivery_failed",
          lease_token: nil,
          claimed_at: nil,
          lease_expires_at: nil,
          available_at: exhausted ? nil : now + [item.attempt_count.minutes, 5.minutes].min,
          completed_at: nil,
          last_error_code: error_code,
          last_error_detail: error_detail,
        )
      end
      PublicationAttentionNotifier.call(@content_connection)
      render json: {
        outcome: "recorded",
        publication_work: payload(item, token: nil),
      }
    rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ArgumentError => error
      render json: {
        outcome: "rejected",
        reason: failure_reason(error),
        errors: [error.message],
      }, status: :unprocessable_entity
    end

    private

    def payload(item, token:)
      {
        topic_id: item.topic_id,
        resource_id: item.bridge_record&.resource_id,
        action: item.action,
        reason: item.reason,
        source_revision: item.source_revision,
        publication_revision: item.publication_revision,
        policy_revision: item.policy_revision,
        lease_token: token,
        lease_expires_at: item.lease_expires_at&.iso8601(6),
        attempt_count: item.attempt_count,
        last_error_code: item.last_error_code,
      }
    end

    def failure_reason(error)
      {
        "invalid lease token" => "invalid_publication_lease",
        "publication lease expired" => "expired_publication_lease",
      }.fetch(error.message, "invalid_publication_failure")
    end

    def ensure_json_request
      raise Discourse::InvalidParameters.new(:format) unless request.format.json?
    end

    def ensure_enabled
      return if SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled

      render json: { outcome: "rejected", reason: "endpoint_disabled" },
             status: :service_unavailable
    end

    def authenticate_connection
      @content_connection = ContentConnectionAuthenticator.call(request, identity: :catalog)
      render json: { outcome: "rejected", reason: "unauthorized" },
             status: :unauthorized unless @content_connection
    end

    def ensure_publication_scope
      return if performed?
      return if @content_connection.enabled && @content_connection.forum_publication_enabled &&
        @content_connection.allows_direction?("from_discourse")

      render json: { outcome: "rejected", reason: "publication_scope_disabled" },
             status: :forbidden
    end
  end
end
