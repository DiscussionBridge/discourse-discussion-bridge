# frozen_string_literal: true

module Jobs
  class DiscussionBridgeCmsAttentionNotifications < ::Jobs::Base
    sidekiq_options retry: false
    def execute(_args)
      DiscussionBridge::CmsAttentionNotifications.dispatch
    end
  end
end
