# frozen_string_literal: true

class AddReconciledToDiscourseRevisionContext < ActiveRecord::Migration[7.0]
  def up
    change_table :discussion_bridge_bridge_records do |t|
      t.string :source_revision, limit: 255
      t.bigint :source_revision_sequence
      t.text :source_created_at_raw
      t.text :source_updated_at_raw
      t.string :source_content_sha256, limit: 64
      t.bigint :source_content_bytes
      t.string :content_disposition, limit: 32
      t.string :source_context_state, limit: 32
      t.string :source_request_fingerprint, limit: 64
    end
    change_table :discussion_bridge_content_bindings do |t|
      t.string :public_id, limit: 36
      t.string :presentation_mode, limit: 32
      t.string :content_disposition, limit: 32
      t.text :read_more_url
      t.string :applied_source_revision, limit: 255
      t.string :publication_revision, limit: 255
      t.text :synchronized_at_raw
    end
    add_index :discussion_bridge_content_bindings, :public_id, unique: true,
              name: "idx_db_bindings_public_id"
    # No historical row is populated, classified, re-keyed or made updateable.
  end

  def down
    recorded = select_value(<<~SQL)
      SELECT EXISTS (
        SELECT 1 FROM discussion_bridge_bridge_records
        WHERE source_revision IS NOT NULL OR source_revision_sequence IS NOT NULL
          OR source_created_at_raw IS NOT NULL OR source_updated_at_raw IS NOT NULL
          OR source_content_sha256 IS NOT NULL OR source_content_bytes IS NOT NULL
          OR content_disposition IS NOT NULL OR source_context_state IS NOT NULL
          OR source_request_fingerprint IS NOT NULL
      ) OR EXISTS (
        SELECT 1 FROM discussion_bridge_content_bindings
        WHERE public_id IS NOT NULL OR presentation_mode IS NOT NULL
          OR content_disposition IS NOT NULL OR read_more_url IS NOT NULL
          OR applied_source_revision IS NOT NULL OR publication_revision IS NOT NULL
          OR synchronized_at_raw IS NOT NULL
      )
    SQL
    if ActiveModel::Type::Boolean.new.cast(recorded)
      raise ActiveRecord::IrreversibleMigration, "Retain accepted source identity and revision context"
    end
    remove_index :discussion_bridge_content_bindings, name: "idx_db_bindings_public_id"
    remove_columns :discussion_bridge_content_bindings, :public_id, :presentation_mode,
                   :content_disposition, :read_more_url, :applied_source_revision,
                   :publication_revision, :synchronized_at_raw
    remove_columns :discussion_bridge_bridge_records, :source_revision,
                   :source_revision_sequence, :source_created_at_raw, :source_updated_at_raw,
                   :source_content_sha256, :source_content_bytes, :content_disposition,
                   :source_context_state, :source_request_fingerprint
  end
end
