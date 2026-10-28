# frozen_string_literal: true

# Fresh, transactional V4 native baseline. No earlier development data conversion.
# Future V4 upgrades use new migrations and retain these durable identities/state.
class CreateDiscussionBridgeV4Baseline < ActiveRecord::Migration[7.0]
  def up
    create_table :discussion_bridge_content_connections do |t|
      t.string :public_id, null: false, limit: 64
      t.string :name, null: false, limit: 120
      t.string :platform, null: false, limit: 32
      t.string :secret_digest, null: false, limit: 64
      t.jsonb :allowed_origins, null: false, default: []
      t.jsonb :allowed_directions, null: false, default: []
      t.jsonb :allowed_lanes, null: false, default: []
      t.string :adapter_id, limit: 100
      t.string :adapter_version, limit: 100
      t.datetime :last_seen_at
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    add_index :discussion_bridge_content_connections, :public_id, unique: true,
              name: "idx_db_content_connections_public_id"
    add_index :discussion_bridge_content_connections, :name, unique: true,
              name: "idx_db_content_connections_name"
    add_index :discussion_bridge_content_connections, :platform,
              name: "idx_db_content_connections_platform"

    create_table :discussion_bridge_bridge_records do |t|
      t.string :resource_id, null: false, limit: 64
      t.string :direction, null: false, limit: 32
      t.string :state, null: false, default: "reserved", limit: 32
      t.string :title, null: false, limit: 1024
      t.bigint :topic_id
      t.bigint :effective_actor_id
      t.string :lane, limit: 64
      t.string :requested_visibility, null: false, default: "unlisted", limit: 32
      t.string :effective_visibility, null: false, default: "unlisted", limit: 32
      t.string :reservation_token, limit: 64
      t.timestamps
    end

    add_index :discussion_bridge_bridge_records, :resource_id, unique: true,
              name: "idx_db_bridge_records_resource_id"
    add_index :discussion_bridge_bridge_records, :topic_id,
              name: "idx_db_bridge_records_topic_id"
    add_index :discussion_bridge_bridge_records, :reservation_token, unique: true,
              name: "idx_db_bridge_records_reservation"
    add_index :discussion_bridge_bridge_records, :state,
              name: "idx_db_bridge_records_state"

    create_table :discussion_bridge_content_bindings do |t|
      t.bigint :bridge_record_id, null: false
      t.bigint :content_connection_id, null: false
      t.string :role, null: false, limit: 32
      t.string :state, null: false, default: "active", limit: 32
      t.string :external_id, null: false, limit: 255
      t.text :canonical_url, null: false
      t.string :identity_digest, null: false, limit: 64
      t.string :canonical_url_digest, null: false, limit: 64
      t.datetime :activated_at
      t.datetime :retired_at
      t.timestamps
    end

    add_index :discussion_bridge_content_bindings, :bridge_record_id,
              name: "idx_db_bindings_bridge_record"
    add_index :discussion_bridge_content_bindings, :content_connection_id,
              name: "idx_db_bindings_content_connection"
    add_index :discussion_bridge_content_bindings, :identity_digest, unique: true,
              name: "idx_db_bindings_identity"
    add_index :discussion_bridge_content_bindings, :canonical_url_digest, unique: true,
              name: "idx_discussion_bridge_bindings_canonical_url"
    add_index :discussion_bridge_content_bindings,
              %i[bridge_record_id role state],
              name: "idx_discussion_bridge_bindings_record_role_state"
    add_index :discussion_bridge_content_bindings,
              %i[bridge_record_id role],
              unique: true,
              where: "state = 'active'",
              name: "idx_discussion_bridge_bindings_one_active"
    add_index :discussion_bridge_content_bindings,
              %i[bridge_record_id role],
              unique: true,
              where: "state = 'prepared'",
              name: "idx_discussion_bridge_bindings_one_prepared"
    add_index :discussion_bridge_content_bindings,
              %i[content_connection_id external_id],
              unique: true,
              name: "idx_discussion_bridge_bindings_connection_external"

    create_table :discussion_bridge_audit_events do |t|
      t.string :correlation_id
      t.string :connection_id, null: false
      t.string :adapter_id
      t.string :source_identity_digest, null: false, limit: 64
      t.bigint :topic_id
      t.bigint :effective_actor_id
      t.string :outcome, null: false
      t.string :reason, null: false
      t.jsonb :requested_state, null: false, default: {}
      t.jsonb :effective_state, null: false, default: {}
      t.timestamps
    end

    add_index :discussion_bridge_audit_events, :correlation_id
    add_index :discussion_bridge_audit_events, :source_identity_digest,
              name: "idx_discussion_bridge_audits_source"
    add_index :discussion_bridge_audit_events, :topic_id
    add_index :discussion_bridge_audit_events, :created_at

    add_column :discussion_bridge_content_connections,
               :authorship_mode,
               :string,
               null: false,
               default: "fixed",
               limit: 32
    add_column :discussion_bridge_content_connections,
               :unmapped_author_policy,
               :string,
               null: false,
               default: "fallback",
               limit: 32

    add_column :discussion_bridge_bridge_records,
               :source_authors,
               :jsonb,
               null: false,
               default: []
    add_column :discussion_bridge_bridge_records,
               :primary_source_author_id,
               :string,
               limit: 255

    create_table :discussion_bridge_source_authors do |t|
      t.bigint :content_connection_id, null: false
      t.string :source_author_id, null: false, limit: 255
      t.string :display_name, null: false, limit: 200
      t.text :profile_url
      t.bigint :discourse_user_id
      t.datetime :last_seen_at, null: false
      t.timestamps
    end

    add_index :discussion_bridge_source_authors,
              %i[content_connection_id source_author_id],
              unique: true,
              name: "idx_db_source_authors_connection_identity"
    add_index :discussion_bridge_source_authors,
              :discourse_user_id,
              name: "idx_db_source_authors_discourse_user"

    add_column :discussion_bridge_content_connections,
               :generate_topic_toc,
               :boolean,
               null: false,
               default: false

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


    create_table :discussion_bridge_cms_configuration_events do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :actor_user_id, null: false
      t.string :previous_policy_revision, limit: 128
      t.string :policy_revision, limit: 128, null: false
      t.jsonb :previous_configuration
      t.jsonb :configuration, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_configuration_events,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_cms_configuration_events,
              %i[content_connection_id created_at id],
              name: "idx_db_cms_configuration_events"

    create_table :discussion_bridge_cms_url_reservations do |t|
      t.bigint :cms_mapping_id, null: false
      t.text :canonical_url, null: false
      t.string :collision_key_sha256, limit: 64, null: false
      t.string :state, limit: 16, null: false
      t.uuid :move_id
      t.datetime :retired_at
      t.timestamps
    end
    add_foreign_key :discussion_bridge_cms_url_reservations,
                    :discussion_bridge_cms_mappings,
                    column: :cms_mapping_id
    add_index :discussion_bridge_cms_url_reservations,
              :collision_key_sha256,
              unique: true,
              name: "idx_db_cms_url_collision"
    add_index :discussion_bridge_cms_url_reservations,
              %i[cms_mapping_id state id],
              name: "idx_db_cms_url_mapping_state"


    create_table :discussion_bridge_cms_url_history_entries do |t|
      t.bigint :cms_mapping_id, null: false
      t.text :url, null: false
      t.datetime :retired_at, null: false
      t.uuid :move_id, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_url_history_entries,
                    :discussion_bridge_cms_mappings,
                    column: :cms_mapping_id
    add_index :discussion_bridge_cms_url_history_entries,
              %i[cms_mapping_id move_id],
              unique: true,
              name: "idx_db_cms_history_mapping_move"
    add_index :discussion_bridge_cms_url_history_entries,
              %i[cms_mapping_id id],
              name: "idx_db_cms_history_mapping_order"

    create_table :discussion_bridge_cms_read_snapshots do |t|
      t.bigint :content_connection_id, null: false
      t.string :kind, limit: 32, null: false
      t.string :path_resource, limit: 36, null: false, default: ""
      t.string :publication_lane, limit: 128, null: false
      t.string :scope_signature, limit: 64, null: false
      t.string :policy_revision, limit: 128, null: false
      t.bigint :item_count, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_read_snapshots,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_cms_read_snapshots,
              %i[content_connection_id created_at],
              name: "idx_db_cms_read_snapshots_owner"

    create_table :discussion_bridge_cms_read_snapshot_items do |t|
      t.bigint :cms_read_snapshot_id, null: false
      t.bigint :ordinal, null: false
      t.jsonb :payload, null: false
    end
    add_foreign_key :discussion_bridge_cms_read_snapshot_items,
                    :discussion_bridge_cms_read_snapshots,
                    column: :cms_read_snapshot_id
    add_index :discussion_bridge_cms_read_snapshot_items,
              %i[cms_read_snapshot_id ordinal],
              unique: true,
              name: "idx_db_cms_read_snapshot_ordinal"

    create_table :discussion_bridge_cms_read_cursors do |t|
      t.bigint :cms_read_snapshot_id, null: false
      t.string :token_digest, limit: 64, null: false
      t.bigint :position, null: false
      t.jsonb :page_body
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_read_cursors,
                    :discussion_bridge_cms_read_snapshots,
                    column: :cms_read_snapshot_id
    add_index :discussion_bridge_cms_read_cursors,
              :token_digest,
              unique: true,
              name: "idx_db_cms_read_cursor_token"

    add_column :discussion_bridge_cms_source_streams,
               :scan_phase,
               :string,
               limit: 16,
               null: false,
               default: "topics"
    add_column :discussion_bridge_cms_source_streams,
               :scan_high_intent_id,
               :bigint
    add_column :discussion_bridge_cms_source_streams,
               :scan_last_intent_id,
               :bigint,
               null: false,
               default: 0
    add_column :discussion_bridge_cms_source_streams,
               :lifecycle_error_code,
               :string,
               limit: 64
    add_column :discussion_bridge_cms_source_streams,
               :lifecycle_failed_at,
               :datetime

    create_table :discussion_bridge_cms_catalog_uploads do |t|
      t.uuid :upload_id, null: false
      t.bigint :content_connection_id, null: false
      t.string :kind, limit: 16, null: false
      t.string :profile, limit: 32, null: false
      t.string :publication_lane, limit: 64, null: false
      t.text :destination_origin, null: false
      t.string :scope_signature, limit: 64, null: false
      t.string :native_revision, limit: 128, null: false
      t.bigint :total_items, null: false
      t.bigint :received_items, null: false, default: 0
      t.bigint :next_page, null: false, default: 0
      t.string :state, limit: 16, null: false, default: "open"
      t.datetime :expires_at, null: false
      t.datetime :invalidated_at
      t.jsonb :finalized_response
      t.timestamps
    end
    add_foreign_key :discussion_bridge_cms_catalog_uploads,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_cms_catalog_uploads,
              :upload_id,
              unique: true,
              name: "idx_db_cms_catalog_upload_uuid"
    add_index :discussion_bridge_cms_catalog_uploads,
              %i[content_connection_id kind publication_lane],
              name: "idx_db_cms_catalog_upload_owner"
    add_check_constraint :discussion_bridge_cms_catalog_uploads,
                         "total_items BETWEEN 0 AND 9007199254740991 AND " \
                           "received_items BETWEEN 0 AND total_items AND " \
                           "next_page BETWEEN 0 AND 9007199254740991",
                         name: "db_cms_catalog_upload_counters"

    create_table :discussion_bridge_cms_catalog_pages do |t|
      t.bigint :catalog_upload_id, null: false
      t.bigint :page, null: false
      t.jsonb :entries, null: false
      t.jsonb :acknowledgement, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_catalog_pages,
                    :discussion_bridge_cms_catalog_uploads,
                    column: :catalog_upload_id
    add_index :discussion_bridge_cms_catalog_pages,
              %i[catalog_upload_id page],
              unique: true,
              name: "idx_db_cms_catalog_page_identity"

    create_table :discussion_bridge_cms_catalog_entries do |t|
      t.bigint :catalog_upload_id, null: false
      t.bigint :ordinal, null: false
      t.text :entry_id, null: false
      t.string :entry_id_sha256, limit: 64, null: false
      t.jsonb :payload, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_catalog_entries,
                    :discussion_bridge_cms_catalog_uploads,
                    column: :catalog_upload_id
    add_index :discussion_bridge_cms_catalog_entries,
              %i[catalog_upload_id entry_id_sha256],
              unique: true,
              name: "idx_db_cms_catalog_entry_identity"
    add_index :discussion_bridge_cms_catalog_entries,
              %i[catalog_upload_id ordinal],
              unique: true,
              name: "idx_db_cms_catalog_entry_order"

    create_table :discussion_bridge_cms_catalog_snapshots do |t|
      t.bigint :catalog_upload_id, null: false
      t.bigint :content_connection_id, null: false
      t.string :kind, limit: 16, null: false
      t.string :profile, limit: 32, null: false
      t.string :publication_lane, limit: 64, null: false
      t.text :destination_origin, null: false
      t.string :catalog_revision, limit: 128, null: false
      t.string :native_revision, limit: 128, null: false
      t.bigint :total_items, null: false
      t.boolean :active, null: false, default: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_catalog_snapshots,
                    :discussion_bridge_cms_catalog_uploads,
                    column: :catalog_upload_id
    add_foreign_key :discussion_bridge_cms_catalog_snapshots,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_cms_catalog_snapshots,
              :catalog_upload_id,
              unique: true,
              name: "idx_db_cms_catalog_snapshot_upload"
    add_index :discussion_bridge_cms_catalog_snapshots,
              :catalog_revision,
              unique: true,
              name: "idx_db_cms_catalog_snapshot_revision"
    add_index :discussion_bridge_cms_catalog_snapshots,
              %i[content_connection_id kind publication_lane],
              unique: true,
              where: "active = TRUE",
              name: "idx_db_cms_catalog_snapshot_active"

    create_table :discussion_bridge_cms_catalog_cursors do |t|
      t.bigint :catalog_snapshot_id, null: false
      t.string :scope_signature, limit: 64, null: false
      t.string :token_digest, limit: 64, null: false
      t.bigint :position, null: false
      t.datetime :expires_at, null: false
      t.datetime :invalidated_at
      t.jsonb :page_body
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_catalog_cursors,
                    :discussion_bridge_cms_catalog_snapshots,
                    column: :catalog_snapshot_id
    add_index :discussion_bridge_cms_catalog_cursors,
              :token_digest,
              unique: true,
              name: "idx_db_cms_catalog_cursor_token"

    # Withdrawn and attention native identities remain reserved.
    add_index :discussion_bridge_cms_mappings,
              %i[content_connection_id destination_native_id],
              unique: true,
              where: "destination_native_id IS NOT NULL",
              name: "idx_db_cms_mapping_native_identity"

    add_column :discussion_bridge_cms_source_cursors, :invalidated_at, :datetime
    add_column :discussion_bridge_cms_read_snapshots, :invalidated_at, :datetime

    create_table :discussion_bridge_cms_scope_events do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :actor_user_id
      t.string :event_origin, limit: 64, null: false
      t.string :reason, limit: 64, null: false
      t.jsonb :changed_fields, null: false
      t.jsonb :previous_values, null: false
      t.jsonb :values, null: false
      t.string :previous_policy_revision, limit: 128
      t.string :policy_revision, limit: 128
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_scope_events,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    # Historical actor IDs remain truthful if native user deletion removes the
    # user. No invented replacement actor, cascade or native user-delete gate.
    add_index :discussion_bridge_cms_scope_events,
              %i[content_connection_id created_at id],
              name: "idx_db_cms_scope_events_owner"

    add_column :discussion_bridge_bridge_records, :cms_source_publication, :jsonb
    create_table :discussion_bridge_cms_to_source_revisions do |t|
      t.bigint :bridge_record_id, null: false
      t.string :source_revision, limit: 128, null: false
      t.string :identity_sha256, limit: 64, null: false
      t.datetime :accepted_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_to_source_revisions,
                    :discussion_bridge_bridge_records, column: :bridge_record_id
    add_index :discussion_bridge_cms_to_source_revisions,
              %i[bridge_record_id source_revision], unique: true,
              name: "idx_db_cms_to_source_revision"

    change_column_null :discussion_bridge_cms_url_reservations, :cms_mapping_id, true
    add_column :discussion_bridge_cms_url_reservations, :content_binding_id, :bigint
    add_foreign_key :discussion_bridge_cms_url_reservations, :discussion_bridge_content_bindings, column: :content_binding_id
    add_check_constraint :discussion_bridge_cms_url_reservations,
      "(cms_mapping_id IS NULL) <> (content_binding_id IS NULL)", name: "db_cms_url_exact_owner"

    create_table :discussion_bridge_cms_url_moves do |t|
      t.uuid :move_id, null: false
      t.bigint :content_connection_id, null: false
      t.bigint :content_binding_id, null: false
      t.bigint :cms_mapping_id
      t.string :kind, limit: 16, null: false
      t.string :state, limit: 16, null: false, default: "prepared"
      t.string :expected_revision, limit: 128, null: false
      t.text :old_url, null: false
      t.text :new_url, null: false
      t.string :proof_nonce, limit: 43, null: false
      t.jsonb :authority
      t.jsonb :old_ownership
      t.jsonb :native_proof
      t.datetime :prepared_at, null: false
      t.timestamps
    end
    add_index :discussion_bridge_cms_url_moves, :move_id, unique: true, name: "idx_db_cms_url_move_uuid"
    add_index :discussion_bridge_cms_url_moves, %i[content_binding_id state], name: "idx_db_cms_url_move_binding"
    add_foreign_key :discussion_bridge_cms_url_moves, :discussion_bridge_content_connections, column: :content_connection_id
    add_foreign_key :discussion_bridge_cms_url_moves, :discussion_bridge_content_bindings, column: :content_binding_id
    add_foreign_key :discussion_bridge_cms_url_moves, :discussion_bridge_cms_mappings, column: :cms_mapping_id

    change_column_null :discussion_bridge_cms_url_history_entries, :cms_mapping_id, true
    add_column :discussion_bridge_cms_url_history_entries, :content_binding_id, :bigint
    add_foreign_key :discussion_bridge_cms_url_history_entries, :discussion_bridge_content_bindings, column: :content_binding_id
    add_check_constraint :discussion_bridge_cms_url_history_entries,
      "(cms_mapping_id IS NULL) <> (content_binding_id IS NULL)", name: "db_cms_history_exact_owner"
    add_index :discussion_bridge_cms_url_history_entries, %i[content_binding_id move_id],
      unique: true, name: "idx_db_cms_source_history_move"
    add_column :discussion_bridge_content_connections, :author_user_id, :bigint
    add_column :discussion_bridge_content_connections, :default_category_id, :bigint
    add_column :discussion_bridge_content_bindings, :presentation_mode, :string, limit: 16
    add_column :discussion_bridge_cms_mutation_receipts, :native_actor_user_id, :bigint
    add_column :discussion_bridge_cms_work, :same_intent_hold, :boolean, null: false, default: false
    add_column :discussion_bridge_cms_mappings, :presentation_move_intent, :jsonb
    add_index :discussion_bridge_content_connections, :author_user_id, name: "idx_db_content_connections_author"
    add_index :discussion_bridge_content_connections, :default_category_id, name: "idx_db_content_connections_category"
    add_index :discussion_bridge_bridge_records, :topic_id, unique: true,
      where: "direction = 'to_discourse'", name: "idx_db_bridge_records_to_topic"

    create_table :discussion_bridge_cms_native_publication_events do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :cms_mapping_id, null: false
      t.bigint :actor_user_id, null: false
      t.string :event_kind, null: false, limit: 32
      t.jsonb :facts, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_native_publication_events, :discussion_bridge_content_connections, column: :content_connection_id
    add_foreign_key :discussion_bridge_cms_native_publication_events, :discussion_bridge_cms_mappings, column: :cms_mapping_id
    add_index :discussion_bridge_cms_native_publication_events, %i[cms_mapping_id created_at id], name: "idx_db_cms_native_publication_events"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "V4 identities, discussions, receipts and pending authority must be retained; restore a protected matching recovery point instead of dropping the baseline"
  end
end
