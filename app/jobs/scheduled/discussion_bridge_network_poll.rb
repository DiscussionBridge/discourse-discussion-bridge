# frozen_string_literal: true

module ::Jobs
  class DiscussionBridgeNetworkPoll < ::Jobs::Scheduled
    every 1.minute

    def execute(_args)
      return unless SiteSetting.discussion_bridge_enabled &&
        SiteSetting.discussion_bridge_publisher_enabled
      return unless DiscussionBridgeForumIdentity.current&.ready?

      DiscussionBridgeNetworkReplay.where("expires_at <= ?", Time.zone.now).delete_all
      DiscussionBridgeNetworkPeer.where(enabled: true).order(:id).find_each do |peer|
        DiscussionBridge::NetworkWorker.call(peer)
      end
    end
  end
end
