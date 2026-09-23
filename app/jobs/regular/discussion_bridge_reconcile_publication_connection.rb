# frozen_string_literal: true

module Jobs
  class DiscussionBridgeReconcilePublicationConnection < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.discussion_bridge_enabled

      connection = DiscussionBridgeContentConnection.find_by(id: args[:connection_id])
      return unless connection

      DiscussionBridge::PublicationWorkQueue.reconcile_connection!(connection)
    end
  end
end
