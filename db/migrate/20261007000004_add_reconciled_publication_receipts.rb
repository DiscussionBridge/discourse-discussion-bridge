# frozen_string_literal: true

class AddReconciledPublicationReceipts < ActiveRecord::Migration[7.0]
  def up
    # Existing work remains unknown, not retrospectively classified by today's
    # connection settings. New work snapshots its approved native profile mode.
    add_column :discussion_bridge_publication_works, :destination_mode, :string, limit: 16
    add_column :discussion_bridge_publication_destinations, :binding, :jsonb
    add_column :discussion_bridge_publication_destinations, :binding_digest, :string, limit: 64
    add_column :discussion_bridge_publication_destinations, :binding_public_id, :string, limit: 36
    add_column :discussion_bridge_publication_destinations, :native_identity_digest, :string, limit: 64
    add_column :discussion_bridge_publication_destinations, :native_url_digest, :string, limit: 64
    add_column :discussion_bridge_publication_destinations, :last_receipt_work_id, :bigint
    %i[binding_public_id native_identity_digest native_url_digest].each do |column|
      add_index :discussion_bridge_publication_destinations, column, unique: true, name: "idx_db_destination_#{column}"
    end
    add_foreign_key :discussion_bridge_publication_destinations, :discussion_bridge_publication_works, column: :last_receipt_work_id

    create_table :discussion_bridge_publication_receipts do |t|
      t.bigint :work_issue_id, null: false
      t.string :stage, limit: 16, null: false
      t.jsonb :request, null: false
      t.string :request_digest, limit: 64, null: false
      t.jsonb :response, null: false
      t.string :response_digest, limit: 64, null: false
      t.datetime :received_at, null: false
    end
    add_index :discussion_bridge_publication_receipts, %i[work_issue_id stage], unique: true, name: "idx_db_receipt_issue_stage"
    add_foreign_key :discussion_bridge_publication_receipts, :discussion_bridge_work_issues, column: :work_issue_id
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM discussion_bridge_publication_receipts)") ||
        select_value("SELECT EXISTS (SELECT 1 FROM discussion_bridge_publication_destinations WHERE binding IS NOT NULL)") ||
        select_value("SELECT EXISTS (SELECT 1 FROM discussion_bridge_publication_works WHERE destination_mode IS NOT NULL)")
      raise ActiveRecord::IrreversibleMigration, "Retain issued destination mode, binding and acknowledgement history"
    end
    drop_table :discussion_bridge_publication_receipts
    remove_foreign_key :discussion_bridge_publication_destinations, column: :last_receipt_work_id
    %i[binding binding_digest binding_public_id native_identity_digest native_url_digest last_receipt_work_id].each do |column|
      remove_column :discussion_bridge_publication_destinations, column
    end
    remove_column :discussion_bridge_publication_works, :destination_mode
  end
end
