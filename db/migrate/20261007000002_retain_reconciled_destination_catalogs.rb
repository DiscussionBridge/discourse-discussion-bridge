# frozen_string_literal: true

class RetainReconciledDestinationCatalogs < ActiveRecord::Migration[7.0]
  def up
    create_table :discussion_bridge_catalog_revisions do |t|
      t.bigint :content_connection_id, null: false
      t.string :platform_profile, limit: 32, null: false
      t.string :public_id, limit: 255, null: false
      t.datetime :created_at, null: false
    end
    add_index :discussion_bridge_catalog_revisions, :public_id, unique: true, name: "idx_db_catalog_revision_public"
    add_index :discussion_bridge_catalog_revisions, %i[content_connection_id platform_profile id], name: "idx_db_catalog_revision_current"
    add_foreign_key :discussion_bridge_catalog_revisions, :discussion_bridge_content_connections, column: :content_connection_id

    create_table :discussion_bridge_catalog_items do |t|
      t.bigint :catalog_revision_id, null: false
      t.string :segment_type, limit: 32, null: false
      t.string :item_id, limit: 255, null: false
      t.jsonb :value, null: false
    end
    add_index :discussion_bridge_catalog_items, %i[catalog_revision_id segment_type item_id], unique: true, name: "idx_db_catalog_item_identity"
    add_foreign_key :discussion_bridge_catalog_items, :discussion_bridge_catalog_revisions, column: :catalog_revision_id

    create_table :discussion_bridge_destination_policies do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :catalog_revision_id, null: false
      t.bigint :approved_by_id, null: false
      t.string :destination_policy_id, limit: 255, null: false
      t.string :policy_revision, limit: 255, null: false
      t.string :platform_profile, limit: 32, null: false
      t.jsonb :definition, null: false
      t.datetime :created_at, null: false
    end
    add_index :discussion_bridge_destination_policies, :policy_revision, unique: true, name: "idx_db_destination_policy_revision"
    add_index :discussion_bridge_destination_policies, %i[content_connection_id destination_policy_id id], name: "idx_db_destination_policy_current"
    add_foreign_key :discussion_bridge_destination_policies, :discussion_bridge_content_connections, column: :content_connection_id
    add_foreign_key :discussion_bridge_destination_policies, :discussion_bridge_catalog_revisions, column: :catalog_revision_id
    add_foreign_key :discussion_bridge_destination_policies, :users, column: :approved_by_id
    # No legacy binding conversion, default mapping, native mutation or work creation.
  end

  def down
    %w[discussion_bridge_catalog_revisions discussion_bridge_catalog_items discussion_bridge_destination_policies].each do |table|
      if select_value("SELECT EXISTS (SELECT 1 FROM #{table})")
        raise ActiveRecord::IrreversibleMigration, "Retain catalogs and approved destination-policy history"
      end
    end
    drop_table :discussion_bridge_destination_policies
    drop_table :discussion_bridge_catalog_items
    drop_table :discussion_bridge_catalog_revisions
  end
end
