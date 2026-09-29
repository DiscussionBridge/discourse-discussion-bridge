# frozen_string_literal: true

class CreateDiscussionBridgePublicationOverrides < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_publication_overrides do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :topic_id, null: false
      t.bigint :set_by_id, null: false
      t.string :decision, null: false, limit: 16
      t.timestamps null: false
    end

    add_index :discussion_bridge_publication_overrides,
              %i[content_connection_id topic_id],
              unique: true,
              name: "idx_db_publication_override_connection_topic"
    add_index :discussion_bridge_publication_overrides,
              :topic_id,
              name: "idx_db_publication_override_topic"
  end
end
