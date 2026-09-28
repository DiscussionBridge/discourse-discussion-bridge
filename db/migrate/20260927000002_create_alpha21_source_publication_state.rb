# frozen_string_literal: true

class CreateAlpha21SourcePublicationState < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_source_revisions do |table|
      table.bigint :bridge_record_id, null: false
      table.string :source_revision, null: false, limit: 255
      table.bigint :source_revision_sequence, null: false
      table.string :fingerprint, null: false, limit: 64
      table.text :topic_url, null: false
      table.string :title, null: false, limit: 1024
      table.datetime :source_created_at, null: false
      table.datetime :source_updated_at, null: false
      table.jsonb :source_authors, null: false, default: []
      table.jsonb :categories, null: false, default: []
      table.jsonb :tags, null: false, default: []
      table.string :presentation_mode, null: false, limit: 32
      table.text :content_html, null: false
      table.bigint :byte_length, null: false
      table.string :content_sha256, null: false, limit: 64
      table.jsonb :network_provenance
      table.timestamps
      table.index :bridge_record_id, name: "idx_db_source_revisions_record"
    end
    add_foreign_key :discussion_bridge_source_revisions,
                    :discussion_bridge_bridge_records,
                    column: :bridge_record_id
    add_index :discussion_bridge_source_revisions,
              %i[bridge_record_id source_revision],
              unique: true,
              name: "idx_db_source_revisions_record_revision"
    add_index :discussion_bridge_source_revisions,
              %i[bridge_record_id source_revision_sequence],
              unique: true,
              name: "idx_db_source_revisions_record_sequence"
    add_index :discussion_bridge_source_revisions,
              %i[bridge_record_id fingerprint],
              name: "idx_db_source_revisions_record_fingerprint"

    create_table :discussion_bridge_source_snapshots do |table|
      table.bigint :content_connection_id, null: false
      table.string :snapshot_id, null: false, limit: 36
      table.string :policy_revision, null: false, limit: 255
      table.datetime :last_read_at, null: false
      table.datetime :expires_at, null: false
      table.datetime :completed_at
      table.timestamps
      table.index :content_connection_id, name: "idx_db_source_snapshots_connection"
    end
    add_foreign_key :discussion_bridge_source_snapshots,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_source_snapshots,
              :snapshot_id,
              unique: true,
              name: "idx_db_source_snapshots_public_id"

    create_table :discussion_bridge_source_snapshot_items do |table|
      table.bigint :source_snapshot_id, null: false
      table.bigint :source_revision_id, null: false
      table.bigint :ordinal, null: false
      table.timestamps
      table.index :source_snapshot_id, name: "idx_db_source_snapshot_items_snapshot"
      table.index :source_revision_id, name: "idx_db_source_snapshot_items_revision"
    end
    add_foreign_key :discussion_bridge_source_snapshot_items,
                    :discussion_bridge_source_snapshots,
                    column: :source_snapshot_id
    add_foreign_key :discussion_bridge_source_snapshot_items,
                    :discussion_bridge_source_revisions,
                    column: :source_revision_id
    add_index :discussion_bridge_source_snapshot_items,
              %i[source_snapshot_id ordinal],
              unique: true,
              name: "idx_db_source_snapshot_items_ordinal"
    add_index :discussion_bridge_source_snapshot_items,
              %i[source_snapshot_id source_revision_id],
              unique: true,
              name: "idx_db_source_snapshot_items_unique_revision"

    create_table :discussion_bridge_source_revocations do |table|
      table.bigint :bridge_record_id, null: false
      table.bigint :content_connection_id, null: false
      table.string :revocation_id, null: false, limit: 36
      table.string :source_revision, null: false, limit: 255
      table.bigint :source_revision_sequence, null: false
      table.string :reason, null: false, limit: 32
      table.datetime :effective_at, null: false
      table.boolean :restorable, null: false, default: true
      table.jsonb :affected_binding_ids, null: false, default: []
      table.string :policy_revision, null: false, limit: 255
      table.datetime :restored_at
      table.timestamps
      table.index :bridge_record_id, name: "idx_db_source_revocations_record"
      table.index :content_connection_id, name: "idx_db_source_revocations_connection"
    end
    add_foreign_key :discussion_bridge_source_revocations,
                    :discussion_bridge_bridge_records,
                    column: :bridge_record_id
    add_foreign_key :discussion_bridge_source_revocations,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_source_revocations,
              :revocation_id,
              unique: true,
              name: "idx_db_source_revocations_public_id"
    add_index :discussion_bridge_source_revocations,
              %i[bridge_record_id source_revision_sequence],
              unique: true,
              name: "idx_db_source_revocations_record_sequence"
  end
end
