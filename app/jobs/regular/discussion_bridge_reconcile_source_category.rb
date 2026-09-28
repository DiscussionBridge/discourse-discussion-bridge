# frozen_string_literal: true

module Jobs
  class DiscussionBridgeReconcileSourceCategory < ::Jobs::Base
    def execute(args)
      category_id = Integer(args[:category_id], exception: false)
      after_topic_id = Integer(args[:after_topic_id] || 0, exception: false)
      return unless category_id&.positive? && after_topic_id && after_topic_id >= 0

      DiscussionBridge::SourcePublicationLifecycle.enqueue_category(
        category_id,
        after_topic_id: after_topic_id,
      )
    end
  end
end
