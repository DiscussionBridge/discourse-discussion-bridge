# frozen_string_literal: true

class AddSourceAuthorshipToDiscussionBridge < ActiveRecord::Migration[7.0]
  def change
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
  end
end
