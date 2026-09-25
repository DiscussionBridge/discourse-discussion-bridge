# frozen_string_literal: true

module DiscussionBridge
  class OperatorServiceMailer < ActionMailer::Base
    def service_event(service:, event:, requested_by:)
      provider = DiscussionBridge::OperatorProviderRegistry.fetch_available(service.provider_id)
      subject = "DiscussionBridge Operator service #{event}: #{Discourse.base_url}"
      body = <<~TEXT
        DiscussionBridge Operator service event

        Event: #{event}
        Provider ID: #{provider[:id]}
        Provider: #{provider[:display_name]}
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
        to: provider[:service_request_email],
        from: SiteSetting.notification_email,
        subject: subject,
        body: body,
        content_type: "text/plain",
      )
    end
  end
end

