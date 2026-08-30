# frozen_string_literal: true

class AddAuthorToDiscussionBridgeContentConnections < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    execute <<~SQL
      ALTER TABLE discussion_bridge_content_connections
      ADD COLUMN IF NOT EXISTS author_user_id bigint
    SQL
    remove_index :discussion_bridge_content_connections,
                 name: "idx_db_content_connections_author",
                 if_exists: true
    add_index :discussion_bridge_content_connections,
              :author_user_id,
              name: "idx_db_content_connections_author",
              algorithm: :concurrently
    remove_index :discussion_bridge_bridge_records,
                 name: "idx_db_bridge_records_topic_id",
                 if_exists: true
    add_index :discussion_bridge_bridge_records,
              :topic_id,
              name: "idx_db_bridge_records_topic_id",
              algorithm: :concurrently
  end

  def down
    remove_index :discussion_bridge_bridge_records,
                 name: "idx_db_bridge_records_topic_id",
                 if_exists: true
    add_index :discussion_bridge_bridge_records,
              :topic_id,
              unique: true,
              name: "idx_db_bridge_records_topic_id",
              algorithm: :concurrently
    remove_index :discussion_bridge_content_connections,
                 name: "idx_db_content_connections_author",
                 if_exists: true
    execute <<~SQL
      ALTER TABLE discussion_bridge_content_connections
      DROP COLUMN IF EXISTS author_user_id
    SQL
  end
end
