# frozen_string_literal: true

module Jobs
  class DiscussionBridgeReconcilePublicationTopic < ::Jobs::Base
    def execute(args)
      topic_id = Integer(args[:topic_id], exception: false)
      return unless topic_id&.positive?
      return unless SiteSetting.discussion_bridge_enabled

      DiscussionBridge::PublicationWorkQueue.reconcile_topic!(topic_id: topic_id)
    end
  end
end
