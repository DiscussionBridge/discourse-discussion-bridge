# frozen_string_literal: true

class AddCmsSourceDelivery < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_cms_source_streams do |t|
      t.bigint :content_connection_id, null: false
      t.string :publication_lane, limit: 120, null: false
      t.bigint :event_sequence, null: false, default: 0
      t.bigint :source_scope_revision, null: false, default: 0
      t.string :scan_state, limit: 16, null: false, default: "uninitialized"
      t.string :scan_scope_signature, limit: 64
      t.bigint :scan_high_topic_id
      t.bigint :scan_last_topic_id, null: false, default: 0
      t.datetime :scan_completed_at
      t.timestamps
    end
    add_index :discussion_bridge_cms_source_streams,
              %i[content_connection_id publication_lane],
              unique: true,
              name: "idx_db_cms_stream_connection_lane"
    add_foreign_key :discussion_bridge_cms_source_streams,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id

    create_table :discussion_bridge_cms_source_intents do |t|
      t.bigint :cms_source_stream_id, null: false
      t.bigint :topic_id, null: false
      t.string :source_id, limit: 255, null: false
      t.string :state, limit: 16, null: false
      t.string :current_source_revision, limit: 128
      t.bigint :publication_event_id
      t.string :attention_code, limit: 64
      t.timestamps
    end
    add_index :discussion_bridge_cms_source_intents,
              %i[cms_source_stream_id source_id],
              unique: true,
              name: "idx_db_cms_intent_stream_source"
    add_index :discussion_bridge_cms_source_intents,
              %i[cms_source_stream_id state],
              name: "idx_db_cms_intent_stream_state"
    add_foreign_key :discussion_bridge_cms_source_intents,
                    :discussion_bridge_cms_source_streams,
                    column: :cms_source_stream_id

    create_table :discussion_bridge_cms_source_revisions do |t|
      t.bigint :cms_source_intent_id, null: false
      t.string :source_revision, limit: 128, null: false
      t.jsonb :source_metadata, null: false
      t.binary :content_bytes_blob, null: false
      t.timestamps
    end
    add_index :discussion_bridge_cms_source_revisions,
              %i[cms_source_intent_id source_revision],
              unique: true,
              name: "idx_db_cms_revision_intent_revision"
    add_foreign_key :discussion_bridge_cms_source_revisions,
                    :discussion_bridge_cms_source_intents,
                    column: :cms_source_intent_id

    create_table :discussion_bridge_cms_source_events do |t|
      t.bigint :cms_source_stream_id, null: false
      t.bigint :cms_source_intent_id, null: false
      t.uuid :event_id, null: false
      t.bigint :event_sequence, null: false
      t.jsonb :payload, null: false
      t.timestamps
    end
    add_index :discussion_bridge_cms_source_events,
              %i[cms_source_stream_id event_sequence],
              unique: true,
              name: "idx_db_cms_event_stream_sequence"
    add_index :discussion_bridge_cms_source_events,
              :event_id,
              unique: true,
              name: "idx_db_cms_event_uuid"
    add_foreign_key :discussion_bridge_cms_source_events,
                    :discussion_bridge_cms_source_streams,
                    column: :cms_source_stream_id
    add_foreign_key :discussion_bridge_cms_source_events,
                    :discussion_bridge_cms_source_intents,
                    column: :cms_source_intent_id
    add_foreign_key :discussion_bridge_cms_source_intents,
                    :discussion_bridge_cms_source_events,
                    column: :publication_event_id

    create_table :discussion_bridge_cms_source_cursors do |t|
      t.bigint :cms_source_stream_id, null: false
      t.bigint :snapshot_root_id
      t.string :token_digest, limit: 64, null: false
      t.string :kind, limit: 16, null: false
      t.string :scope_signature, limit: 64, null: false
      t.string :policy_revision, limit: 128, null: false
      t.bigint :high_water, null: false
      t.bigint :position, null: false, default: 0
      t.bigint :snapshot_count, null: false, default: 0
      t.jsonb :page_body
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :discussion_bridge_cms_source_cursors,
              :token_digest,
              unique: true,
              name: "idx_db_cms_cursor_token"
    add_foreign_key :discussion_bridge_cms_source_cursors,
                    :discussion_bridge_cms_source_streams,
                    column: :cms_source_stream_id
    add_foreign_key :discussion_bridge_cms_source_cursors,
                    :discussion_bridge_cms_source_cursors,
                    column: :snapshot_root_id

    create_table :discussion_bridge_cms_source_snapshot_items do |t|
      t.bigint :snapshot_root_id, null: false
      t.bigint :cms_source_event_id, null: false
      t.bigint :ordinal, null: false
    end
    add_index :discussion_bridge_cms_source_snapshot_items,
              %i[snapshot_root_id ordinal],
              unique: true,
              name: "idx_db_cms_snapshot_root_ordinal"
    add_foreign_key :discussion_bridge_cms_source_snapshot_items,
                    :discussion_bridge_cms_source_cursors,
                    column: :snapshot_root_id
    add_foreign_key :discussion_bridge_cms_source_snapshot_items,
                    :discussion_bridge_cms_source_events,
                    column: :cms_source_event_id
  end
end
