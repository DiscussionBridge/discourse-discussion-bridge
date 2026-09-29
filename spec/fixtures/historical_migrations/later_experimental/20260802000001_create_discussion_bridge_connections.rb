# frozen_string_literal: true

class CreateDiscussionBridgeConnections < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_connections do |t|
      t.string :connection_id, null: false
      t.text :canonical_source_url, null: false
      t.string :source_identity_digest, null: false, limit: 64
      t.string :state, null: false, default: "reserved"
      t.string :reservation_token, limit: 64
      t.bigint :topic_id
      t.bigint :effective_actor_id
      t.string :lane
      t.string :requested_visibility, null: false
      t.string :effective_visibility, null: false
      t.jsonb :requested_state, null: false, default: {}
      t.jsonb :effective_state, null: false, default: {}
      t.timestamps
    end

    add_index :discussion_bridge_connections, :source_identity_digest, unique: true,
              name: "idx_discussion_bridge_connections_source"
    add_index :discussion_bridge_connections, :topic_id, unique: true
    add_index :discussion_bridge_connections, :reservation_token, unique: true
  end
end
