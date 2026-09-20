# frozen_string_literal: true

class CreateDiscussionBridgePublicationWorkItems < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_publication_work_items do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :topic_id, null: false
      t.bigint :bridge_record_id
      t.string :action, null: false, limit: 32
      t.string :state, null: false, limit: 32
      t.string :reason, limit: 64
      t.string :source_revision, limit: 128
      t.string :publication_revision, limit: 64
      t.string :policy_revision, limit: 64
      t.string :lease_token, limit: 64
      t.datetime :available_at
      t.datetime :claimed_at
      t.datetime :lease_expires_at
      t.datetime :completed_at
      t.integer :attempt_count, null: false, default: 0
      t.string :last_error_code, limit: 64
      t.string :last_error_detail, limit: 1000
      t.timestamps null: false
    end

    add_index :discussion_bridge_publication_work_items,
              %i[content_connection_id topic_id],
              unique: true,
              name: "idx_db_publication_work_connection_topic"
    add_index :discussion_bridge_publication_work_items,
              %i[state available_at],
              name: "idx_db_publication_work_state_available"
    add_index :discussion_bridge_publication_work_items,
              :bridge_record_id,
              name: "idx_db_publication_work_bridge_record"
  end
end
