# frozen_string_literal: true

class AddDefaultCategoryToDiscussionBridgeContentConnections < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    execute <<~SQL
      ALTER TABLE discussion_bridge_content_connections
      ADD COLUMN IF NOT EXISTS default_category_id bigint
    SQL
    remove_index :discussion_bridge_content_connections,
                 name: "idx_db_content_connections_default_category",
                 if_exists: true
    add_index :discussion_bridge_content_connections,
              :default_category_id,
              name: "idx_db_content_connections_default_category",
              algorithm: :concurrently
  end

  def down
    remove_index :discussion_bridge_content_connections,
                 name: "idx_db_content_connections_default_category",
                 if_exists: true
    remove_column :discussion_bridge_content_connections,
                  :default_category_id,
                  if_exists: true
  end
end
