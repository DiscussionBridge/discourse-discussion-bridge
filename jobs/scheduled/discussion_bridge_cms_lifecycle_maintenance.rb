# frozen_string_literal: true

module Jobs
  class DiscussionBridgeCmsLifecycleMaintenance < ::Jobs::Scheduled
    every DiscussionBridge::CmsSourceLifecycle::DISPATCH_SECONDS.seconds
    sidekiq_options retry: false

    def execute(_args)
      DiscussionBridge::CmsAttentionNotifications.dispatch
      DiscussionBridge::CmsWorkCoordinator.maintenance
      DiscussionBridge::CmsSourceLifecycle.maintenance
    end
  end
end
