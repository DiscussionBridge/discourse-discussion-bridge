# frozen_string_literal: true

class AddCmsNativeCatalogs < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_cms_catalog_uploads do |t|
      t.uuid :upload_id, null: false
      t.bigint :content_connection_id, null: false
      t.string :kind, limit: 16, null: false
      t.string :profile, limit: 32, null: false
      t.string :publication_lane, limit: 64, null: false
      t.text :destination_origin, null: false
      t.string :scope_signature, limit: 64, null: false
      t.string :native_revision, limit: 128, null: false
      t.bigint :total_items, null: false
      t.bigint :received_items, null: false, default: 0
      t.bigint :next_page, null: false, default: 0
      t.string :state, limit: 16, null: false, default: "open"
      t.datetime :expires_at, null: false
      t.datetime :invalidated_at
      t.jsonb :finalized_response
      t.timestamps
    end
    add_foreign_key :discussion_bridge_cms_catalog_uploads,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_cms_catalog_uploads,
              :upload_id,
              unique: true,
              name: "idx_db_cms_catalog_upload_uuid"
    add_index :discussion_bridge_cms_catalog_uploads,
              %i[content_connection_id kind publication_lane],
              name: "idx_db_cms_catalog_upload_owner"
    add_check_constraint :discussion_bridge_cms_catalog_uploads,
                         "total_items BETWEEN 0 AND 9007199254740991 AND " \
                           "received_items BETWEEN 0 AND total_items AND " \
                           "next_page BETWEEN 0 AND 9007199254740991",
                         name: "db_cms_catalog_upload_counters"

    create_table :discussion_bridge_cms_catalog_pages do |t|
      t.bigint :catalog_upload_id, null: false
      t.bigint :page, null: false
      t.jsonb :entries, null: false
      t.jsonb :acknowledgement, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_catalog_pages,
                    :discussion_bridge_cms_catalog_uploads,
                    column: :catalog_upload_id
    add_index :discussion_bridge_cms_catalog_pages,
              %i[catalog_upload_id page],
              unique: true,
              name: "idx_db_cms_catalog_page_identity"

    create_table :discussion_bridge_cms_catalog_entries do |t|
      t.bigint :catalog_upload_id, null: false
      t.bigint :ordinal, null: false
      t.text :entry_id, null: false
      t.string :entry_id_sha256, limit: 64, null: false
      t.jsonb :payload, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_catalog_entries,
                    :discussion_bridge_cms_catalog_uploads,
                    column: :catalog_upload_id
    add_index :discussion_bridge_cms_catalog_entries,
              %i[catalog_upload_id entry_id_sha256],
              unique: true,
              name: "idx_db_cms_catalog_entry_identity"
    add_index :discussion_bridge_cms_catalog_entries,
              %i[catalog_upload_id ordinal],
              unique: true,
              name: "idx_db_cms_catalog_entry_order"

    create_table :discussion_bridge_cms_catalog_snapshots do |t|
      t.bigint :catalog_upload_id, null: false
      t.bigint :content_connection_id, null: false
      t.string :kind, limit: 16, null: false
      t.string :profile, limit: 32, null: false
      t.string :publication_lane, limit: 64, null: false
      t.text :destination_origin, null: false
      t.string :catalog_revision, limit: 128, null: false
      t.string :native_revision, limit: 128, null: false
      t.bigint :total_items, null: false
      t.boolean :active, null: false, default: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_catalog_snapshots,
                    :discussion_bridge_cms_catalog_uploads,
                    column: :catalog_upload_id
    add_foreign_key :discussion_bridge_cms_catalog_snapshots,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_cms_catalog_snapshots,
              :catalog_upload_id,
              unique: true,
              name: "idx_db_cms_catalog_snapshot_upload"
    add_index :discussion_bridge_cms_catalog_snapshots,
              :catalog_revision,
              unique: true,
              name: "idx_db_cms_catalog_snapshot_revision"
    add_index :discussion_bridge_cms_catalog_snapshots,
              %i[content_connection_id kind publication_lane],
              unique: true,
              where: "active = TRUE",
              name: "idx_db_cms_catalog_snapshot_active"

    create_table :discussion_bridge_cms_catalog_cursors do |t|
      t.bigint :catalog_snapshot_id, null: false
      t.string :scope_signature, limit: 64, null: false
      t.string :token_digest, limit: 64, null: false
      t.bigint :position, null: false
      t.datetime :expires_at, null: false
      t.datetime :invalidated_at
      t.jsonb :page_body
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_catalog_cursors,
                    :discussion_bridge_cms_catalog_snapshots,
                    column: :catalog_snapshot_id
    add_index :discussion_bridge_cms_catalog_cursors,
              :token_digest,
              unique: true,
              name: "idx_db_cms_catalog_cursor_token"
  end
end
