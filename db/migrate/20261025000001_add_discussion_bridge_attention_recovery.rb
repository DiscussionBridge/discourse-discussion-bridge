# frozen_string_literal: true

class AddDiscussionBridgeAttentionRecovery < ActiveRecord::Migration[7.0]
  def up
    add_column :discussion_bridge_cms_work, :retry_of_work_id, :bigint
    add_index :discussion_bridge_cms_work, :retry_of_work_id, unique: true,
              name: "idx_db_cms_work_retry_predecessor"
    add_foreign_key :discussion_bridge_cms_work, :discussion_bridge_cms_work,
                    column: :retry_of_work_id

    create_table :discussion_bridge_cms_attention_inspections do |t|
      t.uuid :inspection_id, null: false
      t.bigint :content_connection_id, null: false
      t.bigint :cms_mapping_id, null: false
      t.bigint :cms_work_id, null: false
      t.bigint :actor_user_id, null: false
      t.string :context_sha256, null: false, limit: 64
      t.jsonb :payload_tree, null: false
      t.jsonb :observation_tree
      t.string :status, null: false, default: "waiting", limit: 32
      t.string :issue, null: false, default: "none", limit: 64
      t.datetime :observed_at
      t.timestamps
    end
    add_index :discussion_bridge_cms_attention_inspections, :inspection_id, unique: true,
              name: "idx_db_attention_inspection_uuid"
    add_index :discussion_bridge_cms_attention_inspections, %i[content_connection_id id],
              name: "idx_db_attention_inspection_feed"
    add_index :discussion_bridge_cms_attention_inspections, %i[cms_work_id id],
              name: "idx_db_attention_inspection_work"
    add_foreign_key :discussion_bridge_cms_attention_inspections, :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_foreign_key :discussion_bridge_cms_attention_inspections, :discussion_bridge_cms_mappings,
                    column: :cms_mapping_id
    add_foreign_key :discussion_bridge_cms_attention_inspections, :discussion_bridge_cms_work,
                    column: :cms_work_id

    create_table :discussion_bridge_cms_attention_recoveries do |t|
      t.uuid :recovery_id, null: false
      t.bigint :content_connection_id, null: false
      t.bigint :cms_mapping_id, null: false
      t.bigint :inspection_record_id, null: false
      t.bigint :predecessor_work_id, null: false
      t.bigint :successor_work_id, null: false
      t.bigint :actor_user_id, null: false
      t.string :context_sha256, null: false, limit: 64
      t.string :mode, null: false, limit: 32
      t.jsonb :payload_tree, null: false
      t.jsonb :attention_snapshot, null: false
      t.datetime :created_at, null: false
    end
    add_index :discussion_bridge_cms_attention_recoveries, :recovery_id, unique: true,
              name: "idx_db_attention_recovery_uuid"
    add_index :discussion_bridge_cms_attention_recoveries, :predecessor_work_id, unique: true,
              name: "idx_db_attention_recovery_predecessor"
    add_index :discussion_bridge_cms_attention_recoveries, :successor_work_id, unique: true,
              name: "idx_db_attention_recovery_successor"
    add_index :discussion_bridge_cms_attention_recoveries, %i[content_connection_id id],
              name: "idx_db_attention_recovery_feed"
    add_foreign_key :discussion_bridge_cms_attention_recoveries, :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_foreign_key :discussion_bridge_cms_attention_recoveries, :discussion_bridge_cms_mappings,
                    column: :cms_mapping_id
    add_foreign_key :discussion_bridge_cms_attention_recoveries, :discussion_bridge_cms_attention_inspections,
                    column: :inspection_record_id
    %i[predecessor_work_id successor_work_id].each do |column|
      add_foreign_key :discussion_bridge_cms_attention_recoveries, :discussion_bridge_cms_work,
                      column: column
    end

    create_table :discussion_bridge_cms_attention_notices do |t|
      t.bigint :cms_work_id, null: false
      t.bigint :content_connection_id, null: false
      t.uuid :attempt_cycle, null: false
      t.jsonb :attention_snapshot, null: false
      t.datetime :created_at, null: false
    end
    add_index :discussion_bridge_cms_attention_notices, %i[cms_work_id attempt_cycle], unique: true,
              name: "idx_db_attention_notice_occurrence"
    add_foreign_key :discussion_bridge_cms_attention_notices, :discussion_bridge_cms_work,
                    column: :cms_work_id
    create_table :discussion_bridge_cms_attention_deliveries do |t|
      t.bigint :notice_id, null: false
      t.bigint :user_id, null: false
      t.bigint :notification_id
      t.datetime :delivered_at
      t.datetime :skipped_at
    end
    add_index :discussion_bridge_cms_attention_deliveries, %i[notice_id user_id], unique: true,
              name: "idx_db_attention_notice_recipient"
    add_foreign_key :discussion_bridge_cms_attention_deliveries, :discussion_bridge_cms_attention_notices,
                    column: :notice_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Attention snapshots, explicit retry lineage and delivery history must be retained"
  end
end
