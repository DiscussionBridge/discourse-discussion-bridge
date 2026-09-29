# frozen_string_literal: true

class AddAlpha21RevisionAndCapabilityState < ActiveRecord::Migration[7.0]
  def up
    add_column_unless_exists :discussion_bridge_content_connections, :destination_policies, :jsonb,
                             null: false, default: []
    add_column_unless_exists :discussion_bridge_content_connections, :catalog_required, :boolean,
                             null: false, default: false
    add_column_unless_exists :discussion_bridge_content_connections, :policy_revision, :string, limit: 255

    add_column_unless_exists :discussion_bridge_bridge_records, :presentation_mode, :string, limit: 32
    add_column_unless_exists :discussion_bridge_bridge_records, :source_revision, :string, limit: 255
    add_column_unless_exists :discussion_bridge_bridge_records, :source_revision_sequence, :bigint
    add_column_unless_exists :discussion_bridge_bridge_records, :source_created_at, :datetime
    add_column_unless_exists :discussion_bridge_bridge_records, :source_updated_at, :datetime
    add_column_unless_exists :discussion_bridge_bridge_records, :content_disposition, :string, limit: 16
    add_column_unless_exists :discussion_bridge_bridge_records, :source_content_bytes, :bigint
    add_column_unless_exists :discussion_bridge_bridge_records, :source_content_sha256, :string, limit: 64
    add_column_unless_exists :discussion_bridge_bridge_records, :delivered_content_sha256, :string, limit: 64

    add_column_unless_exists :discussion_bridge_content_bindings, :binding_id, :string, limit: 36
    add_column_unless_exists :discussion_bridge_content_bindings, :presentation_mode, :string, limit: 32
    add_column_unless_exists :discussion_bridge_content_bindings, :applied_source_revision, :string, limit: 255
    add_column_unless_exists :discussion_bridge_content_bindings, :publication_revision, :string, limit: 255
    add_column_unless_exists :discussion_bridge_content_bindings, :content_disposition, :string, limit: 16
    add_column_unless_exists :discussion_bridge_content_bindings, :synchronized_at, :datetime
    add_column_unless_exists :discussion_bridge_content_bindings, :deployment_state, :string,
                             null: false, default: "not_required", limit: 32
    add_column_unless_exists :discussion_bridge_content_bindings, :deployed_at, :datetime
    add_column_unless_exists :discussion_bridge_content_bindings, :verification_state, :string,
                             null: false, default: "not_required", limit: 32
    add_column_unless_exists :discussion_bridge_content_bindings, :publicly_verified_at, :datetime

    connection.select_values("SELECT id FROM discussion_bridge_content_bindings WHERE binding_id IS NULL").each do |id|
      binding_id = "dbb_#{SecureRandom.hex(16)}"
      execute <<~SQL
        UPDATE discussion_bridge_content_bindings
        SET binding_id = #{connection.quote(binding_id)}
        WHERE id = #{Integer(id)}
      SQL
    end
    change_column_null :discussion_bridge_content_bindings, :binding_id, false
    add_index :discussion_bridge_content_bindings, :binding_id, unique: true,
              name: "idx_db_content_bindings_public_id" unless
      index_exists?(:discussion_bridge_content_bindings, :binding_id, unique: true)
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Alpha.21 state can coexist with later experimental history and must be restored from backup"
  end

  private

  def add_column_unless_exists(table, column, type, **options)
    add_column(table, column, type, **options) unless column_exists?(table, column)
  end
end
