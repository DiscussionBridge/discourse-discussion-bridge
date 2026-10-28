# frozen_string_literal: true

module DiscussionBridge
  class SupportMailer < ActionMailer::Base
    include Email::BuildEmailHelper

    def request_assistance(row)
      body = [
        "Contact email address: #{row.contact_email}",
        "Forum URL: #{row.forum_url}",
        "Plugin version: #{row.plugin_version}",
        "Request ID: #{row.request_id}",
        "Problem description:", row.problem,
      ].join("\n")
      build_email(row.request_destination,
        subject: "DiscussionBridge support request #{row.request_id}", body: body).tap do |message|
        message["Auto-Submitted"] = "auto-generated"
      end
    end
  end
end
