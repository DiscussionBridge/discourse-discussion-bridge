# frozen_string_literal: true

class AddCmsPublicationWork < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_content_connections, :cms_configuration, :jsonb

    create_table :discussion_bridge_cms_mappings do |t|
      t.uuid :mapping_id, null: false
      t.bigint :content_connection_id, null: false
      t.bigint :content_binding_id, null: false
      t.string :source_id, limit: 255, null: false
      t.string :mapping_revision, limit: 128, null: false
      t.string :mapping_state, limit: 16, null: false, default: "pending"
      t.bigint :fence_generation, null: false, default: 0
      t.string :destination_native_id, limit: 255
      t.string :destination_native_revision, limit: 128
      t.string :desired_source_revision, limit: 128
      t.string :synchronized_source_revision, limit: 128
      t.string :publicly_verified_source_revision, limit: 128
      t.datetime :source_created_at
      t.datetime :source_updated_at
      t.datetime :synchronized_at
      t.datetime :publicly_verified_at
      t.jsonb :native_result
      t.jsonb :verified_result
      t.jsonb :prepared_transaction
      t.timestamps
    end
    add_index :discussion_bridge_cms_mappings, :mapping_id, unique: true, name: "idx_db_cms_mapping_uuid"
    add_index :discussion_bridge_cms_mappings, :content_binding_id, unique: true, name: "idx_db_cms_mapping_binding"
    add_index :discussion_bridge_cms_mappings, %i[content_connection_id source_id], unique: true, name: "idx_db_cms_mapping_source"
    add_foreign_key :discussion_bridge_cms_mappings, :discussion_bridge_content_connections, column: :content_connection_id
    add_foreign_key :discussion_bridge_cms_mappings, :discussion_bridge_content_bindings, column: :content_binding_id

    create_table :discussion_bridge_cms_work do |t|
      t.uuid :work_id, null: false
      t.bigint :cms_mapping_id, null: false
      t.string :source_revision, limit: 128
      t.string :policy_revision, limit: 128, null: false
      t.string :action, limit: 32, null: false
      t.string :state, limit: 32, null: false, default: "pending"
      t.uuid :attempt_cycle, null: false
      t.integer :attempt, null: false, default: 0
      t.bigint :lease_generation, null: false, default: 0
      t.string :lease_verifier, limit: 64
      t.datetime :lease_expires_at
      t.datetime :retry_at
      t.string :last_failure_code, limit: 64
      t.jsonb :source_snapshot
      t.jsonb :failure_detail
      t.timestamps
    end
    add_index :discussion_bridge_cms_work, :work_id, unique: true, name: "idx_db_cms_work_uuid"
    add_index :discussion_bridge_cms_work, %i[cms_mapping_id state], name: "idx_db_cms_work_mapping_state"
    add_foreign_key :discussion_bridge_cms_work, :discussion_bridge_cms_mappings, column: :cms_mapping_id

    create_table :discussion_bridge_cms_mutation_receipts do |t|
      t.bigint :content_connection_id, null: false
      t.string :route, limit: 64, null: false
      t.string :path_resource, limit: 36, null: false, default: ""
      t.uuid :mutation_id, null: false
      t.jsonb :request_tree, null: false
      t.integer :response_status, null: false
      t.jsonb :response_body
      t.timestamps
    end
    add_index :discussion_bridge_cms_mutation_receipts,
              %i[content_connection_id route path_resource mutation_id],
              unique: true, name: "idx_db_cms_mutation_identity"
    add_foreign_key :discussion_bridge_cms_mutation_receipts,
                    :discussion_bridge_content_connections, column: :content_connection_id
  end
end
