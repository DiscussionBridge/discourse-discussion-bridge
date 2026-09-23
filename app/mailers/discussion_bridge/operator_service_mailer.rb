# frozen_string_literal: true

module DiscussionBridge
  class OperatorServiceMailer < ActionMailer::Base
    SERVICE_REQUEST_EMAIL = "servicerequest@discussionbridge.dev"

    def service_event(service:, event:, requested_by:)
      subject = "DiscussionBridge Operator service #{event}: #{Discourse.base_url}"
      body = <<~TEXT
        DiscussionBridge Operator service event

        Event: #{event}
        Forum: #{Discourse.base_url}
        Installation ID: #{service.installation_id}
        Enrollment ID: #{service.enrollment_id}
        Requested by: #{requested_by.username}
        Requesting administrator email: #{requested_by.email}
        Plugin version: #{DiscussionBridge::VERSION}
        Requested at: #{Time.zone.now.iso8601}

        This message contains no forum credentials, Content Connection secrets,
        topic content, or forum user census.
      TEXT

      mail(
        to: SERVICE_REQUEST_EMAIL,
        from: SiteSetting.notification_email,
        subject: subject,
        body: body,
        content_type: "text/plain",
      )
    end
  end
end

