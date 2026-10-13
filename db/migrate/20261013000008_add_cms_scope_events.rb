# frozen_string_literal: true

class AddCmsScopeEvents < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_cms_source_cursors, :invalidated_at, :datetime
    add_column :discussion_bridge_cms_read_snapshots, :invalidated_at, :datetime

    create_table :discussion_bridge_cms_scope_events do |t|
      t.bigint :content_connection_id, null: false
      t.bigint :actor_user_id
      t.string :event_origin, limit: 64, null: false
      t.string :reason, limit: 64, null: false
      t.jsonb :changed_fields, null: false
      t.jsonb :previous_values, null: false
      t.jsonb :values, null: false
      t.string :previous_policy_revision, limit: 128
      t.string :policy_revision, limit: 128
      t.datetime :created_at, null: false
    end
    add_foreign_key :discussion_bridge_cms_scope_events,
                    :discussion_bridge_content_connections,
                    column: :content_connection_id
    # Historical actor IDs remain truthful if native user deletion removes the
    # user. No invented replacement actor, cascade or native user-delete gate.
    add_index :discussion_bridge_cms_scope_events,
              %i[content_connection_id created_at id],
              name: "idx_db_cms_scope_events_owner"
  end
end
