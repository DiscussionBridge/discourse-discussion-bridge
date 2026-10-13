# frozen_string_literal: true

class AddCmsMappingReadAndAdoptionState < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_cms_mappings, :adoption_ownership, :jsonb

    create_table :discussion_bridge_cms_url_history_entries do |t|
      t.bigint :cms_mapping_id, null: false
      t.text :url, null: false
      t.datetime :retired_at, null: false
      t.uuid :move_id, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_url_history_entries,
                    :discussion_bridge_cms_mappings,
                    column: :cms_mapping_id
    add_index :discussion_bridge_cms_url_history_entries,
              %i[cms_mapping_id move_id],
              unique: true,
              name: "idx_db_cms_history_mapping_move"
    add_index :discussion_bridge_cms_url_history_entries,
              %i[cms_mapping_id id],
              name: "idx_db_cms_history_mapping_order"

    create_table :discussion_bridge_cms_read_snapshots do |t|
      t.bigint :content_connection_id, null: false
      t.string :kind, limit: 32, null: false
      t.string :path_resource, limit: 36, null: false, default: ""
      t.string :publication_lane, limit: 128, null: false
      t.string :scope_signature, limit: 64, null: false
      t.string :policy_revision, limit: 128, null: false
      t.bigint :item_count, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_read_snapshots,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_cms_read_snapshots,
              %i[content_connection_id created_at],
              name: "idx_db_cms_read_snapshots_owner"

    create_table :discussion_bridge_cms_read_snapshot_items do |t|
      t.bigint :cms_read_snapshot_id, null: false
      t.bigint :ordinal, null: false
      t.jsonb :payload, null: false
    end
    add_foreign_key :discussion_bridge_cms_read_snapshot_items,
                    :discussion_bridge_cms_read_snapshots,
                    column: :cms_read_snapshot_id
    add_index :discussion_bridge_cms_read_snapshot_items,
              %i[cms_read_snapshot_id ordinal],
              unique: true,
              name: "idx_db_cms_read_snapshot_ordinal"

    create_table :discussion_bridge_cms_read_cursors do |t|
      t.bigint :cms_read_snapshot_id, null: false
      t.string :token_digest, limit: 64, null: false
      t.bigint :position, null: false
      t.jsonb :page_body
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_read_cursors,
                    :discussion_bridge_cms_read_snapshots,
                    column: :cms_read_snapshot_id
    add_index :discussion_bridge_cms_read_cursors,
              :token_digest,
              unique: true,
              name: "idx_db_cms_read_cursor_token"
  end
end
