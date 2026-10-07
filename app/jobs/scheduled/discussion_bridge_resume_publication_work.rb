# frozen_string_literal: true

module Jobs
  # Resume SQL progress if a process exits before/after a Redis wake-up. Oldest
  # updated cursors rotate to the back after each successful bounded step.
  class DiscussionBridgeResumePublicationWork < ::Jobs::Scheduled
    every 1.minute

    def execute(_args)
      return unless ::DiscussionBridge::SourceRevocationProducer.enabled?
      ids = DiscussionBridgePolicyProduction.where(complete: false).joins(destination_policy: :content_connection)
        .where(discussion_bridge_content_connections: { enabled: true })
        .where("discussion_bridge_content_connections.allowed_directions @> ?::jsonb", '["from_discourse"]')
        .order(:updated_at, :id).limit(10).pluck(:id)
      ids.each { |id| ::DiscussionBridge::PublicationWorkProducer.resume!(id) }
    end
  end
end
