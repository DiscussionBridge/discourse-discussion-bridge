# frozen_string_literal: true

class RetainPublicationRetryAuthorizations < ActiveRecord::Migration[7.0]
  def up
    create_table :discussion_bridge_publication_retries do |t|
      t.bigint :publication_work_id, null: false
      t.bigint :publication_failure_id, null: false
      t.bigint :actor_id, null: false
      t.integer :prior_generation, null: false
      t.integer :retry_generation, null: false
      t.jsonb :request, null: false
      t.string :request_digest, limit: 64, null: false
      t.string :evidence_digest, limit: 64, null: false
      t.jsonb :response, null: false
      t.string :response_digest, limit: 64, null: false
      t.datetime :performed_at, null: false
      t.string :performed_at_raw, limit: 255, null: false
    end
    add_index :discussion_bridge_publication_retries, %i[publication_work_id prior_generation], unique: true, name: "idx_db_retry_generation"
    add_foreign_key :discussion_bridge_publication_retries, :discussion_bridge_publication_works, column: :publication_work_id
    add_foreign_key :discussion_bridge_publication_retries, :discussion_bridge_publication_failures, column: :publication_failure_id
    add_foreign_key :discussion_bridge_publication_retries, :users, column: :actor_id
    # Migration authorizes no retry and fabricates no correction evidence.
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM discussion_bridge_publication_retries)")
      raise ActiveRecord::IrreversibleMigration, "Retain operator correction evidence and retry history"
    end
    drop_table :discussion_bridge_publication_retries
  end
end
