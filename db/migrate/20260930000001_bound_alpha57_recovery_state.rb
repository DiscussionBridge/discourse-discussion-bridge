# frozen_string_literal: true

class BoundAlpha57RecoveryState < ActiveRecord::Migration[7.0]
  AUDIT_TARGET_LIMIT = 255
  LEGACY_AUDIT_TARGET_LIMIT = 200

  def up
    change_column :discussion_bridge_operator_audit_records,
                  :target_id,
                  :string,
                  limit: AUDIT_TARGET_LIMIT,
                  null: false

    add_index :discussion_bridge_publication_works,
              %i[content_connection_id state next_retry_at id],
              name: "idx_db_publication_works_retry_due",
              if_not_exists: true
    add_index :discussion_bridge_publication_works,
              %i[content_connection_id state lease_expires_at id],
              name: "idx_db_publication_works_lease_due",
              if_not_exists: true

    add_column :discussion_bridge_source_snapshots,
               :source_high_water_record_id,
               :bigint,
               null: false,
               default: 0
    add_column :discussion_bridge_source_snapshots,
               :scan_cursor_record_id,
               :bigint,
               null: false,
               default: 0
    add_column :discussion_bridge_source_snapshots,
               :build_complete,
               :boolean,
               null: false,
               default: false
    execute <<~SQL
      UPDATE discussion_bridge_source_snapshots
      SET source_high_water_record_id = COALESCE((
            SELECT MAX(source_revision.bridge_record_id)
            FROM discussion_bridge_source_snapshot_items AS snapshot_item
            JOIN discussion_bridge_source_revisions AS source_revision
              ON source_revision.id = snapshot_item.source_revision_id
            WHERE snapshot_item.source_snapshot_id = discussion_bridge_source_snapshots.id
          ), 0),
          scan_cursor_record_id = COALESCE((
            SELECT MAX(source_revision.bridge_record_id)
            FROM discussion_bridge_source_snapshot_items AS snapshot_item
            JOIN discussion_bridge_source_revisions AS source_revision
              ON source_revision.id = snapshot_item.source_revision_id
            WHERE snapshot_item.source_snapshot_id = discussion_bridge_source_snapshots.id
          ), 0),
          build_complete = TRUE
    SQL
    add_index :discussion_bridge_source_snapshots,
              %i[content_connection_id policy_revision expires_at],
              name: "idx_db_source_snapshots_reusable",
              if_not_exists: true
  end

  def down
    overlong = select_value(<<~SQL)
      SELECT 1
      FROM discussion_bridge_operator_audit_records
      WHERE octet_length(target_id) > #{LEGACY_AUDIT_TARGET_LIMIT}
      LIMIT 1
    SQL
    raise ActiveRecord::IrreversibleMigration,
          "operator audit target identifiers exceed the legacy 200-byte limit" if overlong

    remove_index :discussion_bridge_source_snapshots,
                 name: "idx_db_source_snapshots_reusable",
                 if_exists: true
    remove_column :discussion_bridge_source_snapshots, :build_complete
    remove_column :discussion_bridge_source_snapshots, :scan_cursor_record_id
    remove_column :discussion_bridge_source_snapshots, :source_high_water_record_id

    remove_index :discussion_bridge_publication_works,
                 name: "idx_db_publication_works_lease_due",
                 if_exists: true
    remove_index :discussion_bridge_publication_works,
                 name: "idx_db_publication_works_retry_due",
                 if_exists: true
    change_column :discussion_bridge_operator_audit_records,
                  :target_id,
                  :string,
                  limit: LEGACY_AUDIT_TARGET_LIMIT,
                  null: false
  end
end
