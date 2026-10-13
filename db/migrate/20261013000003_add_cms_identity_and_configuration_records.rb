# frozen_string_literal: true

class AddCmsIdentityAndConfigurationRecords < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_content_bindings,
               :cms_protocol_version,
               :integer,
               null: false,
               default: 1

    create_table :discussion_bridge_cms_configuration_events do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :actor_user_id, null: false
      t.string :previous_policy_revision, limit: 128
      t.string :policy_revision, limit: 128, null: false
      t.jsonb :previous_configuration
      t.jsonb :configuration, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_configuration_events,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    add_index :discussion_bridge_cms_configuration_events,
              %i[content_connection_id created_at id],
              name: "idx_db_cms_configuration_events"

    create_table :discussion_bridge_cms_url_reservations do |t|
      t.bigint :cms_mapping_id, null: false
      t.text :canonical_url, null: false
      t.string :collision_key_sha256, limit: 64, null: false
      t.string :state, limit: 16, null: false
      t.uuid :move_id
      t.datetime :retired_at
      t.timestamps
    end
    add_foreign_key :discussion_bridge_cms_url_reservations,
                    :discussion_bridge_cms_mappings,
                    column: :cms_mapping_id
    add_index :discussion_bridge_cms_url_reservations,
              :collision_key_sha256,
              unique: true,
              name: "idx_db_cms_url_collision"
    add_index :discussion_bridge_cms_url_reservations,
              %i[cms_mapping_id state id],
              name: "idx_db_cms_url_mapping_state"
  end
end
