# frozen_string_literal: true

module DiscussionBridge
  class ProductOverview
    def self.call
      connections = DiscussionBridgeContentConnection.all
      records = DiscussionBridgeBridgeRecord.all
      issue_summary = BridgeReconciliationIndex.summary
      actor = User.find_by(username_lower: SiteSetting.discussion_bridge_service_username.to_s.downcase)
      blockers = []
      blockers << "plugin_disabled" unless SiteSetting.discussion_bridge_enabled
      blockers << "endpoint_disabled" unless SiteSetting.discussion_bridge_endpoint_enabled
      blockers << "operating_identity_missing" unless actor
      blockers << "forum_category_missing" unless Category.exists?(id: SiteSetting.discussion_bridge_effective_category_id)
      blockers << "content_connections_missing" unless connections.exists?
      blockers << "content_connections_unverified" if connections.where(enabled: true, last_seen_at: nil).exists?

      {
        product: {
          name: "DiscussionBridge",
          version: DiscussionBridge::VERSION,
          health: blockers.empty? && issue_summary[:total].zero? ? "healthy" : "attention",
        },
        metrics: {
          content_connections: connections.count,
          bridge_records: records.count,
          needs_attention: issue_summary[:total],
        },
        directions: {
          to_discourse: records.where(direction: "to_discourse").count,
          from_discourse: records.where(direction: "from_discourse").count,
        },
        readiness: {
          ready: blockers.empty?,
          blockers: blockers,
          plugin_enabled: SiteSetting.discussion_bridge_enabled,
          endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
          operating_identity: actor && { id: actor.id, username: actor.username },
        },
        connections: connections.order(:name).limit(10).map do |connection|
          {
            id: connection.id,
            public_id: connection.public_id,
            name: connection.name,
            platform: connection.platform,
            enabled: connection.enabled,
            bridge_record_count: connection.content_bindings.where(state: "active").distinct.count(:bridge_record_id),
            last_seen_at: connection.last_seen_at,
          }
        end,
      }
    end
  end
end
