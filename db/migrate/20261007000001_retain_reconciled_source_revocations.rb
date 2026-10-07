# frozen_string_literal: true

class RetainReconciledSourceRevocations < ActiveRecord::Migration[7.0]
  def up
    create_table :discussion_bridge_source_revocations do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :bridge_record_id, null: false
      t.bigint :content_binding_id, null: false
      t.bigint :native_source_revision_id, null: false
      t.string :public_id, limit: 36, null: false
      t.string :resource_id, limit: 36, null: false
      t.string :binding_public_id, limit: 36, null: false
      t.string :source_revision, limit: 255, null: false
      t.bigint :source_revision_sequence, null: false
      t.string :reason, limit: 32, null: false
      t.text :effective_at_raw, null: false
      t.boolean :restorable, null: false
      t.string :identity_digest, limit: 64, null: false
      t.string :context_digest, limit: 64, null: false
    end
    add_index :discussion_bridge_source_revocations, :public_id, unique: true, name: "idx_db_revocation_public"
    add_index :discussion_bridge_source_revocations, :identity_digest, unique: true, name: "idx_db_revocation_identity"
    add_index :discussion_bridge_source_revocations, %i[content_connection_id id], name: "idx_db_revocation_connection_cut"
    add_index :discussion_bridge_source_revocations, %i[content_connection_id resource_id id], name: "idx_db_revocation_resource"
    { content_connection_id: :discussion_bridge_content_connections,
      bridge_record_id: :discussion_bridge_bridge_records,
      content_binding_id: :discussion_bridge_content_bindings,
      native_source_revision_id: :discussion_bridge_native_source_revisions }.each do |column, table|
      add_foreign_key :discussion_bridge_source_revocations, table, column: column
    end

    create_table :discussion_bridge_source_revocation_windows do |t|
      t.bigint :content_connection_id, null: false
      t.string :public_id, limit: 36, null: false
      t.string :policy_revision, limit: 255, null: false
      t.bigint :revocation_cut, null: false
      t.datetime :established_at, null: false
      t.datetime :last_read_at, null: false
    end
    add_index :discussion_bridge_source_revocation_windows, :public_id, unique: true, name: "idx_db_revocation_window_public"
    add_foreign_key :discussion_bridge_source_revocation_windows, :discussion_bridge_content_connections,
                    column: :content_connection_id
    # No historical notices, delivery receipts, source rewrites or row conversion.
  end

  def down
    %w[discussion_bridge_source_revocations discussion_bridge_source_revocation_windows].each do |table|
      if select_value("SELECT EXISTS (SELECT 1 FROM #{table})")
        raise ActiveRecord::IrreversibleMigration, "Retain source withdrawals and issued revocation windows"
      end
    end
    drop_table :discussion_bridge_source_revocation_windows
    drop_table :discussion_bridge_source_revocations
  end
end
