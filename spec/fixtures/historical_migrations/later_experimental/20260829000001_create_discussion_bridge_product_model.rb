# frozen_string_literal: true

class CreateDiscussionBridgeProductModel < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_content_connections do |t|
      t.string :public_id, null: false, limit: 64
      t.string :name, null: false, limit: 120
      t.string :platform, null: false, limit: 32
      t.string :secret_digest, null: false, limit: 64
      t.jsonb :allowed_origins, null: false, default: []
      t.jsonb :allowed_directions, null: false, default: []
      t.jsonb :allowed_lanes, null: false, default: []
      t.string :adapter_id, limit: 100
      t.string :adapter_version, limit: 100
      t.datetime :last_seen_at
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    add_index :discussion_bridge_content_connections, :public_id, unique: true,
              name: "idx_db_content_connections_public_id"
    add_index :discussion_bridge_content_connections, :name, unique: true,
              name: "idx_db_content_connections_name"
    add_index :discussion_bridge_content_connections, :platform,
              name: "idx_db_content_connections_platform"

    create_table :discussion_bridge_bridge_records do |t|
      t.string :resource_id, null: false, limit: 64
      t.string :direction, null: false, limit: 32
      t.string :state, null: false, default: "reserved", limit: 32
      t.string :title, null: false, limit: 1024
      t.bigint :topic_id
      t.bigint :effective_actor_id
      t.string :lane, limit: 64
      t.string :requested_visibility, null: false, default: "unlisted", limit: 32
      t.string :effective_visibility, null: false, default: "unlisted", limit: 32
      t.string :reservation_token, limit: 64
      t.datetime :retry_authorized_at
      t.bigint :retry_authorized_by_id
      t.timestamps
    end

    add_index :discussion_bridge_bridge_records, :resource_id, unique: true,
              name: "idx_db_bridge_records_resource_id"
    add_index :discussion_bridge_bridge_records, :topic_id, unique: true,
              name: "idx_db_bridge_records_topic_id"
    add_index :discussion_bridge_bridge_records, :reservation_token, unique: true,
              name: "idx_db_bridge_records_reservation"
    add_index :discussion_bridge_bridge_records, :state,
              name: "idx_db_bridge_records_state"

    create_table :discussion_bridge_content_bindings do |t|
      t.bigint :bridge_record_id, null: false
      t.bigint :content_connection_id, null: false
      t.string :role, null: false, limit: 32
      t.string :state, null: false, default: "active", limit: 32
      t.string :external_id, null: false, limit: 255
      t.text :canonical_url, null: false
      t.string :identity_digest, null: false, limit: 64
      t.string :canonical_url_digest, null: false, limit: 64
      t.datetime :activated_at
      t.datetime :retired_at
      t.timestamps
    end

    add_index :discussion_bridge_content_bindings, :bridge_record_id,
              name: "idx_db_bindings_bridge_record"
    add_index :discussion_bridge_content_bindings, :content_connection_id,
              name: "idx_db_bindings_content_connection"
    add_index :discussion_bridge_content_bindings, :identity_digest, unique: true,
              name: "idx_db_bindings_identity"
    add_index :discussion_bridge_content_bindings, :canonical_url_digest, unique: true,
              name: "idx_discussion_bridge_bindings_canonical_url"
    add_index :discussion_bridge_content_bindings,
              %i[bridge_record_id role state],
              name: "idx_discussion_bridge_bindings_record_role_state"
    add_index :discussion_bridge_content_bindings,
              %i[bridge_record_id role],
              unique: true,
              where: "state = 'active'",
              name: "idx_discussion_bridge_bindings_one_active"
    add_index :discussion_bridge_content_bindings,
              %i[bridge_record_id role],
              unique: true,
              where: "state = 'prepared'",
              name: "idx_discussion_bridge_bindings_one_prepared"
    add_index :discussion_bridge_content_bindings,
              %i[content_connection_id external_id],
              unique: true,
              name: "idx_discussion_bridge_bindings_connection_external"
  end
end
