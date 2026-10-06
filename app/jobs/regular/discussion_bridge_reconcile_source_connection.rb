# frozen_string_literal: true

module Jobs
  class DiscussionBridgeReconcileSourceConnection < ::Jobs::Base
    def execute(args)
      DiscussionBridge::SourcePublicationLifecycle.reconcile_connection!(
        args[:connection_id],
        after_record_id: args[:after_record_id] || 0,
      )
    end
  end
end
