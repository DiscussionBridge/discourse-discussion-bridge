# frozen_string_literal: true

class AddReconciledPublicationWork < ActiveRecord::Migration[7.0]
  def up
    create_table :discussion_bridge_publication_destinations do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :bridge_record_id, null: false
      t.bigint :content_binding_id, null: false
      t.string :resource_id, limit: 36, null: false
      t.string :destination_policy_id, limit: 255, null: false
      t.bigint :desired_work_id
      t.bigint :active_work_id
      t.timestamps
    end
    add_index :discussion_bridge_publication_destinations, %i[content_connection_id destination_policy_id resource_id], unique: true, name: "idx_db_destination_identity"
    add_foreign_key :discussion_bridge_publication_destinations, :discussion_bridge_content_connections, column: :content_connection_id
    add_foreign_key :discussion_bridge_publication_destinations, :discussion_bridge_bridge_records, column: :bridge_record_id
    add_foreign_key :discussion_bridge_publication_destinations, :discussion_bridge_content_bindings, column: :content_binding_id

    create_table :discussion_bridge_publication_works do |t|
      t.bigint :publication_destination_id, null: false
      t.bigint :source_inventory_entry_id, null: false
      t.bigint :destination_policy_id, null: false
      t.string :public_id, limit: 36, null: false
      t.string :identity_digest, limit: 64, null: false
      t.string :context_digest, limit: 64, null: false
      t.jsonb :context, null: false
      t.string :state, limit: 32, null: false, default: "available"
      t.integer :attempt_count, null: false, default: 1
      t.integer :retry_generation, null: false, default: 0
      t.datetime :lease_started_at
      t.datetime :lease_expires_at
      t.integer :total_lease_seconds, null: false, default: 0
      t.string :worker_id, limit: 200
      t.string :lease_token, limit: 64
      t.string :stage_token, limit: 64
      t.timestamps
    end
    add_index :discussion_bridge_publication_works, :public_id, unique: true, name: "idx_db_work_public"
    add_index :discussion_bridge_publication_works, :identity_digest, unique: true, name: "idx_db_work_identity"
    add_index :discussion_bridge_publication_works, %i[state lease_expires_at id], name: "idx_db_work_expiry"
    add_index :discussion_bridge_publication_works, %i[publication_destination_id id], name: "idx_db_work_destination"
    add_foreign_key :discussion_bridge_publication_works, :discussion_bridge_publication_destinations, column: :publication_destination_id
    add_foreign_key :discussion_bridge_publication_works, :discussion_bridge_source_inventory_entries, column: :source_inventory_entry_id
    add_foreign_key :discussion_bridge_publication_works, :discussion_bridge_destination_policies, column: :destination_policy_id
    %i[active_work_id desired_work_id].each do |column|
      add_foreign_key :discussion_bridge_publication_destinations, :discussion_bridge_publication_works, column: column
    end

    create_table :discussion_bridge_work_issues do |t|
      t.bigint :publication_work_id, null: false
      t.jsonb :work, null: false
      t.string :worker_id, limit: 200, null: false
      t.datetime :claimed_at, null: false
    end
    add_foreign_key :discussion_bridge_work_issues, :discussion_bridge_publication_works, column: :publication_work_id

    create_table :discussion_bridge_policy_productions do |t|
      t.bigint :destination_policy_id, null: false
      t.bigint :cut, null: false
      t.bigint :position, null: false, default: 0
      t.boolean :complete, null: false, default: false
      t.timestamps
    end
    add_index :discussion_bridge_policy_productions, :destination_policy_id, unique: true, name: "idx_db_policy_production"
    add_foreign_key :discussion_bridge_policy_productions, :discussion_bridge_destination_policies, column: :destination_policy_id
    # Additive, empty state only. No populated legacy row is split, reassigned,
    # adopted as a successful receipt, or widened to allow another binding.
  end

  def down
    %w[discussion_bridge_publication_destinations discussion_bridge_publication_works discussion_bridge_work_issues discussion_bridge_policy_productions].each do |table|
      if select_value("SELECT EXISTS (SELECT 1 FROM #{table})")
        raise ActiveRecord::IrreversibleMigration, "Retain exact destination, work and issue history"
      end
    end
    %i[active_work_id desired_work_id].each do |column|
      remove_foreign_key :discussion_bridge_publication_destinations, column: column
    end
    drop_table :discussion_bridge_policy_productions
    drop_table :discussion_bridge_work_issues
    drop_table :discussion_bridge_publication_works
    drop_table :discussion_bridge_publication_destinations
  end
end
