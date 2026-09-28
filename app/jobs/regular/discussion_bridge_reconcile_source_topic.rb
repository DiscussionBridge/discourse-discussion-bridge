# frozen_string_literal: true

module Jobs
  class DiscussionBridgeReconcileSourceTopic < ::Jobs::Base
    def execute(args)
      topic_id = Integer(args[:topic_id], exception: false)
      return unless topic_id&.positive?

      DiscussionBridge::SourcePublicationLifecycle.reconcile_topic!(topic_id)
    end
  end
end
