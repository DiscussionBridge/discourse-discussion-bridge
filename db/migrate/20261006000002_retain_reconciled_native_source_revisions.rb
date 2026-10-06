# frozen_string_literal: true

class RetainReconciledNativeSourceRevisions < ActiveRecord::Migration[7.0]
  def up
    create_table :discussion_bridge_native_source_revisions do |t|
      t.bigint :bridge_record_id, null: false
      t.bigint :sequence, null: false
      t.string :revision, limit: 255, null: false
      t.string :fingerprint, limit: 64, null: false
      t.jsonb :metadata, null: false
      t.text :content_html, null: false
      t.datetime :captured_at, null: false
    end
    add_index :discussion_bridge_native_source_revisions, %i[bridge_record_id sequence],
              unique: true, name: "idx_db_native_source_record_sequence"
    add_index :discussion_bridge_native_source_revisions, %i[bridge_record_id revision],
              unique: true, name: "idx_db_native_source_record_revision"
    # New captures only. Existing records and source content are not backfilled.
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM discussion_bridge_native_source_revisions)")
      raise ActiveRecord::IrreversibleMigration, "Retain captured native source revisions"
    end
    drop_table :discussion_bridge_native_source_revisions
  end
end
