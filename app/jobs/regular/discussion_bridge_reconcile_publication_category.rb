# frozen_string_literal: true

module Jobs
  class DiscussionBridgeReconcilePublicationCategory < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.discussion_bridge_enabled

      category_id = Integer(args[:category_id], exception: false)
      return unless category_id&.positive?

      Topic.with_deleted.where(category_id: category_id).order(:id).pluck(:id).each do |topic_id|
        Jobs.enqueue(:discussion_bridge_reconcile_publication_topic, topic_id: topic_id)
      end
    end
  end
end
