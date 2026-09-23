# frozen_string_literal: true

module Jobs
  class DiscussionBridgeOperatorServiceNotification < ::Jobs::Base
    sidekiq_options queue: "low", retry: 8

    def execute(args)
      service = DiscussionBridgeOperatorService.find(args.fetch(:service_id))
      requested_by = User.find(args.fetch(:requested_by_id))
      event = args.fetch(:event).to_s
      raise Discourse::InvalidParameters unless %w[requested disabled].include?(event)

      message = DiscussionBridge::OperatorServiceMailer.service_event(
        service: service,
        event: event,
        requested_by: requested_by,
      )
      Email::Sender.new(message, :discussion_bridge_operator_service).send
      service.update!(
        notification_state: "sent",
        notification_sent_at: Time.zone.now,
        notification_error: nil,
      )
    rescue => error
      service&.update_columns(
        notification_state: "failed",
        notification_error: error.message.to_s.byteslice(0, 2000),
        updated_at: Time.zone.now,
      )
      raise
    end
  end
end

