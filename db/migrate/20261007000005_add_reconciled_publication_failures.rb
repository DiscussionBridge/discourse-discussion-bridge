# frozen_string_literal: true

class AddReconciledPublicationFailures < ActiveRecord::Migration[7.0]
  def up
    add_column :discussion_bridge_publication_works, :next_retry_at, :datetime
    add_column :discussion_bridge_publication_works, :retry_resume_state, :string, limit: 32
    add_index :discussion_bridge_publication_works, %i[state next_retry_at id], name: "idx_db_work_retry_due"
    create_table :discussion_bridge_publication_failures do |t|
      t.bigint :work_issue_id, null: false
      t.jsonb :request, null: false
      t.string :request_digest, limit: 64, null: false
      t.string :from_state, limit: 32, null: false
      t.string :resulting_state, limit: 32, null: false
      t.datetime :received_at, null: false
      t.datetime :next_retry_at
    end
    add_index :discussion_bridge_publication_failures, :work_issue_id, unique: true, name: "idx_db_failure_issue"
    add_foreign_key :discussion_bridge_publication_failures, :discussion_bridge_work_issues, column: :work_issue_id
    # No historical work is classified, replayed, or retried by migration.
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM discussion_bridge_publication_failures)") ||
        select_value("SELECT EXISTS (SELECT 1 FROM discussion_bridge_publication_works WHERE next_retry_at IS NOT NULL OR retry_resume_state IS NOT NULL)")
      raise ActiveRecord::IrreversibleMigration, "Retain exact failure, retry and static recovery history"
    end
    drop_table :discussion_bridge_publication_failures
    remove_index :discussion_bridge_publication_works, name: "idx_db_work_retry_due"
    remove_column :discussion_bridge_publication_works, :next_retry_at
    remove_column :discussion_bridge_publication_works, :retry_resume_state
  end
end
