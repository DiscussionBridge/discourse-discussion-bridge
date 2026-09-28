# frozen_string_literal: true

class CreateAlpha21OperatorPresentationState < ActiveRecord::Migration[7.0]
  def up
    unless column_exists?(
      :discussion_bridge_content_connections,
      :platform_catalog_refresh_requested_at,
    )
      add_column :discussion_bridge_content_connections,
                 :platform_catalog_refresh_requested_at,
                 :datetime
    end

    ensure_url_history_table(:discussion_bridge_source_url_histories, "source")
    ensure_url_history_table(:discussion_bridge_presentation_url_histories, "presentation")
    ensure_publication_overrides_table
    execute <<~SQL
      UPDATE discussion_bridge_publication_overrides
      SET decision = 'include', updated_at = CURRENT_TIMESTAMP
      WHERE decision = 'publish'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "operator state may predate this compatibility migration"
  end

  private

  def ensure_url_history_table(table_name, prefix)
    unless table_exists?(table_name)
      create_table table_name do |table|
        table.bigint :bridge_record_id, null: false
        table.bigint :content_binding_id, null: false
        table.bigint :verified_by_id, null: false
        table.text :old_canonical_url, null: false
        table.text :new_canonical_url, null: false
        table.string :old_canonical_url_digest, null: false, limit: 64
        table.integer :redirect_status, null: false
        table.datetime :verified_at, null: false
        table.timestamps
      end
    end

    add_index table_name, :bridge_record_id,
              name: "idx_db_#{prefix}_url_history_record" unless
      index_exists?(table_name, :bridge_record_id)
    add_index table_name, :content_binding_id,
              name: "idx_db_#{prefix}_url_history_binding" unless
      index_exists?(table_name, :content_binding_id)
    add_index table_name, :old_canonical_url_digest,
              name: "idx_db_#{prefix}_retired_url" unless
      index_exists?(table_name, :old_canonical_url_digest)
    add_foreign_key table_name, :discussion_bridge_bridge_records,
                    column: :bridge_record_id unless
      foreign_key_exists?(table_name, :discussion_bridge_bridge_records,
                          column: :bridge_record_id)
    add_foreign_key table_name, :discussion_bridge_content_bindings,
                    column: :content_binding_id unless
      foreign_key_exists?(table_name, :discussion_bridge_content_bindings,
                          column: :content_binding_id)
    add_foreign_key table_name, :users, column: :verified_by_id unless
      foreign_key_exists?(table_name, :users, column: :verified_by_id)
  end

  def ensure_publication_overrides_table
    unless table_exists?(:discussion_bridge_publication_overrides)
      create_table :discussion_bridge_publication_overrides do |table|
        table.bigint :content_connection_id, null: false
        table.bigint :topic_id, null: false
        table.bigint :set_by_id, null: false
        table.string :decision, null: false, limit: 16
        table.timestamps
      end
    end

    unless index_exists?(:discussion_bridge_publication_overrides, :topic_id)
      add_index :discussion_bridge_publication_overrides, :topic_id,
                name: "idx_db_publication_overrides_topic"
    end
    columns = %i[content_connection_id topic_id]
    unless index_exists?(:discussion_bridge_publication_overrides, columns, unique: true)
      add_index :discussion_bridge_publication_overrides, columns, unique: true,
                name: "idx_db_publication_overrides_unique"
    end
    add_foreign_key :discussion_bridge_publication_overrides,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id unless
      foreign_key_exists?(:discussion_bridge_publication_overrides,
                          :discussion_bridge_content_connections,
                          column: :content_connection_id)
    add_foreign_key :discussion_bridge_publication_overrides, :topics,
                    column: :topic_id unless
      foreign_key_exists?(:discussion_bridge_publication_overrides, :topics,
                          column: :topic_id)
    add_foreign_key :discussion_bridge_publication_overrides, :users,
                    column: :set_by_id unless
      foreign_key_exists?(:discussion_bridge_publication_overrides, :users,
                          column: :set_by_id)
  end
end
