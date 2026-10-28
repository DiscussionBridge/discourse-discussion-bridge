# frozen_string_literal: true

module Jobs
  class DiscussionBridgeSupportRequest < ::Jobs::Base
    def execute(args)
      # Commit 'sending' BEFORE transport. A crash/ambiguous SMTP result never
      # permits a duplicate send on a job retry. Native EmailLog is acceptance by
      # this forum's mailer, not proof of recipient delivery or commercial state.
      row = nil
      DiscussionBridge::SupportAccess.locked do |state|
        row = ::DiscussionBridgeSupportRequest.lock.find_by(id: args[:request_record_id])
        return unless row && %w[pending queued queue_unconfirmed].include?(row.status)
        actor = row.actor
        begin
          DiscussionBridge::CmsAuthorityLifecycle.administrator!(actor)
          allowed = state.enabled && SiteSetting.discussion_bridge_enabled &&
            row.request_destination == DiscussionBridge::SupportWorkflow::REQUEST_DESTINATION &&
            row.request_destination.present?
          raise Discourse::InvalidAccess unless allowed
        rescue Discourse::InvalidAccess
          row.update!(status: "cancelled", failure_code: "consent_or_actor_unavailable")
          return
        end
        row.update!(status: "sending", failure_code: nil)
      end
      return unless row&.status == "sending"

      # Keep support disable/revocation serialized with delivery admission too.
      DiscussionBridge::SupportAccess.locked do |state|
        row.reload
        actor = row.actor
        begin
          DiscussionBridge::CmsAuthorityLifecycle.administrator!(actor)
        rescue Discourse::InvalidAccess
          row.update!(status: "cancelled", failure_code: "consent_or_actor_unavailable")
          return
        end
        unless state.enabled && SiteSetting.discussion_bridge_enabled
          row.update!(status: "cancelled", failure_code: "consent_or_actor_unavailable")
          return
        end
        result = Email::Sender.new(DiscussionBridge::SupportMailer.request_assistance(row), "discussion_bridge_support").send
        accepted = result.is_a?(EmailLog) && result.persisted?
        row.update!(status: accepted ? "submitted_to_mailer" : "delivery_unconfirmed",
          failure_code: accepted ? nil : "native_mailer_did_not_confirm",
          email_log_id: accepted ? result.id : nil, submitted_at: accepted ? Time.current : nil)
        DiscussionBridge::SupportAccess.audit!(actor, "request_mailer_result", request_id: row.request_id, status: row.status)
      end
    rescue StandardError
      # Never persist/log native exception messages: they may contain transport
      # credentials or request text. No automatic second send after ambiguity.
      ::DiscussionBridgeSupportRequest.where(id: row&.id, status: "sending").update_all(
        status: "delivery_unconfirmed", failure_code: "native_mailer_exception", updated_at: Time.current)
    end
  end
end
