# frozen_string_literal: true

class RetainReconciledSourceInventory < ActiveRecord::Migration[7.0]
  def up
    create_table :discussion_bridge_source_inventory_entries do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :bridge_record_id, null: false
      t.bigint :content_binding_id, null: false
      t.bigint :native_source_revision_id, null: false
      t.string :resource_id, limit: 36, null: false
      t.bigint :topic_id, null: false
      t.string :binding_public_id, limit: 36, null: false
      t.text :canonical_url, null: false
      t.string :lane, limit: 100
      t.string :context_digest, limit: 64, null: false
      t.datetime :observed_at, null: false
    end
    add_index :discussion_bridge_source_inventory_entries, %i[content_connection_id id],
              name: "idx_db_inventory_connection_cut"
    add_index :discussion_bridge_source_inventory_entries, %i[content_connection_id bridge_record_id id],
              name: "idx_db_inventory_record_cut"
    add_foreign_key :discussion_bridge_source_inventory_entries, :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_foreign_key :discussion_bridge_source_inventory_entries, :discussion_bridge_bridge_records,
                    column: :bridge_record_id
    add_foreign_key :discussion_bridge_source_inventory_entries, :discussion_bridge_content_bindings,
                    column: :content_binding_id
    add_foreign_key :discussion_bridge_source_inventory_entries, :discussion_bridge_native_source_revisions,
                    column: :native_source_revision_id

    create_table :discussion_bridge_source_inventory_snapshots do |t|
      t.bigint :content_connection_id, null: false
      t.string :public_id, limit: 36, null: false
      t.string :policy_revision, limit: 255, null: false
      t.bigint :observation_cut, null: false
      t.datetime :established_at, null: false
      t.datetime :last_read_at, null: false
    end
    add_index :discussion_bridge_source_inventory_snapshots, :public_id, unique: true,
              name: "idx_db_inventory_snapshot_public"
    add_foreign_key :discussion_bridge_source_inventory_snapshots, :discussion_bridge_content_connections,
                    column: :content_connection_id
    # No historical observations, fabricated revision cuts or row conversion.
  end

  def down
    %w[discussion_bridge_source_inventory_entries discussion_bridge_source_inventory_snapshots].each do |table|
      if select_value("SELECT EXISTS (SELECT 1 FROM #{table})")
        raise ActiveRecord::IrreversibleMigration, "Retain observed source inventory and issued snapshots"
      end
    end
    drop_table :discussion_bridge_source_inventory_snapshots
    drop_table :discussion_bridge_source_inventory_entries
  end
end
