# frozen_string_literal: true

class CreateAlpha21DiscourseNetworkState < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_forum_identities do |table|
      table.string :singleton_key, null: false, default: "current", limit: 16
      table.string :forum_id, null: false, limit: 36
      table.string :site_origin, null: false, limit: 2_048
      table.boolean :enabled, null: false, default: false
      table.jsonb :retired_forum_ids, null: false, default: []
      table.bigint :changed_by_id, null: false
      table.datetime :enabled_at
      table.datetime :disabled_at
      table.datetime :rotated_at
      table.timestamps
    end
    add_index :discussion_bridge_forum_identities,
              :singleton_key,
              unique: true,
              name: "idx_db_forum_identity_singleton"
    add_index :discussion_bridge_forum_identities,
              :forum_id,
              unique: true,
              name: "idx_db_forum_identity_public_id"
    add_foreign_key :discussion_bridge_forum_identities, :users, column: :changed_by_id

    add_column :discussion_bridge_content_connections,
               :network_enabled,
               :boolean,
               null: false,
               default: false
    add_column :discussion_bridge_content_connections,
               :network_peer_forum_id,
               :string,
               limit: 36
    add_column :discussion_bridge_content_connections,
               :network_relationship,
               :string,
               limit: 32
    add_index :discussion_bridge_content_connections,
              %i[network_peer_forum_id network_relationship],
              name: "idx_db_content_connections_network_peer"

    add_column :discussion_bridge_bridge_records, :network_provenance, :jsonb

    create_table :discussion_bridge_network_peers do |table|
      table.bigint :content_connection_id, null: false
      table.string :name, null: false, limit: 120
      table.string :remote_forum_id, null: false, limit: 36
      table.string :remote_forum_name, null: false, limit: 200
      table.string :remote_origin, null: false, limit: 2_048
      table.string :remote_connection_id, null: false, limit: 64
      table.text :remote_secret_ciphertext, null: false
      table.string :relationship, null: false, limit: 32
      table.boolean :enabled, null: false, default: false
      table.bigint :authorized_by_id, null: false
      table.datetime :authorized_at, null: false
      table.datetime :disabled_at
      table.timestamps
    end
    add_foreign_key :discussion_bridge_network_peers,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_foreign_key :discussion_bridge_network_peers, :users, column: :authorized_by_id
    add_index :discussion_bridge_network_peers,
              :content_connection_id,
              unique: true,
              name: "idx_db_network_peers_connection"
    add_index :discussion_bridge_network_peers,
              %i[remote_forum_id relationship],
              unique: true,
              name: "idx_db_network_peers_remote_direction"

    create_table :discussion_bridge_network_replays do |table|
      table.bigint :network_peer_id, null: false
      table.string :origin_forum_id, null: false, limit: 36
      table.string :operation_id, null: false, limit: 36
      table.string :immutable_sha256, null: false, limit: 64
      table.jsonb :immutable_operation, null: false, default: {}
      table.jsonb :retained_result, null: false, default: {}
      table.string :correlation_id, null: false, limit: 200
      table.datetime :expires_at, null: false
      table.timestamps
    end
    add_foreign_key :discussion_bridge_network_replays,
                    :discussion_bridge_network_peers,
                    column: :network_peer_id
    add_index :discussion_bridge_network_replays,
              %i[origin_forum_id operation_id],
              unique: true,
              name: "idx_db_network_replays_operation"
    add_index :discussion_bridge_network_replays,
              :expires_at,
              name: "idx_db_network_replays_expiry"
  end
end
