# frozen_string_literal: true

class AddDiscussionBridgeSupport < ActiveRecord::Migration[7.0]
  def up
    create_table :discussion_bridge_support_states do |t|
      t.boolean :enabled, null: false, default: false
      t.timestamps
    end
    execute "INSERT INTO discussion_bridge_support_states (id, enabled, created_at, updated_at) VALUES (1, false, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    add_check_constraint :discussion_bridge_support_states, "id = 1", name: "db_support_singleton"

    create_table :discussion_bridge_support_grants do |t|
      t.bigint :user_id, null: false
      t.bigint :granted_by_user_id, null: false
      t.datetime :granted_at, null: false
      t.bigint :revoked_by_user_id
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :discussion_bridge_support_grants, :user_id, unique: true, where: "revoked_at IS NULL", name: "db_support_active_user"

    create_table :discussion_bridge_support_requests do |t|
      t.string :request_id, null: false, limit: 36
      t.bigint :actor_user_id, null: false
      t.string :contact_email, null: false, limit: 320
      t.string :request_destination, null: false, limit: 320
      t.text :forum_url, null: false
      t.string :plugin_version, null: false
      t.text :problem, null: false
      t.string :payload_sha256, null: false, limit: 64
      t.string :status, null: false
      t.string :failure_code
      t.bigint :email_log_id
      t.datetime :submitted_at
      t.timestamps
    end
    add_index :discussion_bridge_support_requests, :request_id, unique: true, name: "db_support_request_uuid"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain support consent, access and request history"
  end
end
