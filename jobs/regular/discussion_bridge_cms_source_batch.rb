# frozen_string_literal: true

module Jobs
  class DiscussionBridgeCmsSourceBatch < ::Jobs::Base
    # Durable source state resumes through the bounded dispatcher. A permanent
    # metadata failure must not become an unbounded Sidekiq exception retry.
    sidekiq_options retry: false

    def execute(args)
      if args[:topic_id]
        connection =
          DiscussionBridgeContentConnection.find_by(
            id:
              DiscussionBridge::CmsSourceLifecycle.native_id!(
                args[:connection_id]
              )
          )
        if connection
          DiscussionBridge::CmsSourceLifecycle.refresh(
            connection,
            args[:topic_id]
          )
        end
      else
        DiscussionBridge::CmsSourceLifecycle.run_batch(args[:connection_id])
      end
    end
  end
end
