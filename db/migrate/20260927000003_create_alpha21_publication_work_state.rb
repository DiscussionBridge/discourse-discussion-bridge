# frozen_string_literal: true

class CreateAlpha21PublicationWorkState < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_platform_catalogs do |table|
      table.bigint :content_connection_id, null: false
      table.string :platform_profile, null: false, limit: 32
      table.string :catalog_revision, null: false, limit: 255
      table.boolean :current, null: false, default: false
      table.timestamps
      table.index :content_connection_id, name: "idx_db_platform_catalogs_connection"
    end
    add_foreign_key :discussion_bridge_platform_catalogs,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_platform_catalogs,
              %i[content_connection_id platform_profile catalog_revision],
              unique: true,
              name: "idx_db_platform_catalogs_revision"
    add_index :discussion_bridge_platform_catalogs,
              %i[content_connection_id platform_profile],
              unique: true,
              where: "current = TRUE",
              name: "idx_db_platform_catalogs_current"

    create_table :discussion_bridge_platform_catalog_segments do |table|
      table.bigint :platform_catalog_id, null: false
      table.string :segment_type, null: false, limit: 32
      table.jsonb :items, null: false, default: []
      table.timestamps
      table.index :platform_catalog_id, name: "idx_db_catalog_segments_catalog"
    end
    add_foreign_key :discussion_bridge_platform_catalog_segments,
                    :discussion_bridge_platform_catalogs,
                    column: :platform_catalog_id
    add_index :discussion_bridge_platform_catalog_segments,
              %i[platform_catalog_id segment_type],
              unique: true,
              name: "idx_db_catalog_segments_unique"

    create_table :discussion_bridge_publication_works do |table|
      table.bigint :content_connection_id, null: false
      table.bigint :bridge_record_id, null: false
      table.bigint :content_binding_id, null: false
      table.bigint :source_revision_id
      table.bigint :source_revocation_id
      table.bigint :manual_retry_authorized_by_id
      table.string :work_id, null: false, limit: 36
      table.string :action, null: false, limit: 32
      table.string :state, null: false, limit: 32, default: "available"
      table.string :source_revision, null: false, limit: 255
      table.bigint :source_revision_sequence, null: false
      table.string :policy_revision, null: false, limit: 255
      table.string :destination_policy_id, null: false, limit: 255
      table.string :catalog_revision, null: false, limit: 255
      table.string :presentation_mode, null: false, limit: 32
      table.jsonb :resolved_container, null: false, default: {}
      table.jsonb :resolved_taxonomy, null: false, default: []
      table.jsonb :resolved_author, null: false, default: {}
      table.jsonb :native_limit_policy, null: false, default: {}
      table.integer :attempt_count, null: false, default: 1
      table.integer :retry_generation, null: false, default: 0
      table.string :worker_id, limit: 200
      table.string :lease_token_digest, limit: 64
      table.string :stage_token_digest, limit: 64
      table.integer :total_lease_seconds, null: false, default: 0
      table.datetime :leased_at
      table.datetime :lease_expires_at
      table.datetime :available_at
      table.datetime :next_retry_at
      table.string :last_acknowledged_stage, limit: 32
      table.datetime :synchronized_at
      table.datetime :deployed_at
      table.datetime :publicly_verified_at
      table.string :failure_code, limit: 64
      table.text :failure_detail
      table.datetime :failed_at
      table.string :failure_request_digest, limit: 64
      table.jsonb :failure_response_payload
      table.string :resolution_error, limit: 64
      table.datetime :manual_retry_authorized_at
      table.datetime :acknowledged_at
      table.datetime :superseded_at
      table.timestamps
      table.index :content_connection_id, name: "idx_db_publication_works_connection"
      table.index :bridge_record_id, name: "idx_db_publication_works_record"
      table.index :content_binding_id, name: "idx_db_publication_works_binding"
      table.index :source_revision_id, name: "idx_db_publication_works_revision"
      table.index :source_revocation_id, name: "idx_db_publication_works_revocation"
      table.index %i[content_connection_id state available_at],
                  name: "idx_db_publication_works_claim"
      table.index %i[content_binding_id state], name: "idx_db_publication_works_serial"
    end
    add_foreign_key :discussion_bridge_publication_works,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_foreign_key :discussion_bridge_publication_works,
                    :discussion_bridge_bridge_records,
                    column: :bridge_record_id
    add_foreign_key :discussion_bridge_publication_works,
                    :discussion_bridge_content_bindings,
                    column: :content_binding_id
    add_foreign_key :discussion_bridge_publication_works,
                    :discussion_bridge_source_revisions,
                    column: :source_revision_id
    add_foreign_key :discussion_bridge_publication_works,
                    :discussion_bridge_source_revocations,
                    column: :source_revocation_id
    add_foreign_key :discussion_bridge_publication_works,
                    :users,
                    column: :manual_retry_authorized_by_id
    add_index :discussion_bridge_publication_works,
              :work_id,
              unique: true,
              name: "idx_db_publication_works_public_id"
    add_index :discussion_bridge_publication_works,
              %i[content_connection_id content_binding_id source_revision policy_revision destination_policy_id action],
              unique: true,
              name: "idx_db_publication_works_identity"

    create_table :discussion_bridge_publication_acknowledgements do |table|
      table.bigint :publication_work_id, null: false
      table.string :stage, null: false, limit: 32
      table.string :request_digest, null: false, limit: 64
      table.jsonb :request_payload, null: false, default: {}
      table.jsonb :response_payload, null: false, default: {}
      table.timestamps
      table.index :publication_work_id, name: "idx_db_publication_acks_work"
    end
    add_foreign_key :discussion_bridge_publication_acknowledgements,
                    :discussion_bridge_publication_works,
                    column: :publication_work_id
    add_index :discussion_bridge_publication_acknowledgements,
              %i[publication_work_id stage],
              unique: true,
              name: "idx_db_publication_acks_stage"
  end
end
