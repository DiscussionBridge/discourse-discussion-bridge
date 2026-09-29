# frozen_string_literal: true

class AddRetryAuthorizationToDiscussionBridgeConnections < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_connections, :retry_authorized_at, :datetime
    add_column :discussion_bridge_connections, :retry_authorized_by_id, :bigint
    add_index :discussion_bridge_connections, :retry_authorized_at,
              name: "idx_discussion_bridge_connections_retry"
  end
end
