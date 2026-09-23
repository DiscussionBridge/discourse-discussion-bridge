# frozen_string_literal: true

class CreateDiscussionBridgeOperatorServices < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_operator_services do |t|
      t.string :installation_id, null: false, limit: 36
      t.string :enrollment_id, null: false, limit: 36
      t.boolean :enabled, null: false, default: false
      t.string :status, null: false, default: "inactive", limit: 32
      t.bigint :requested_by_id
      t.datetime :requested_at
      t.datetime :disabled_at
      t.string :notification_state, null: false, default: "not_sent", limit: 32
      t.datetime :notification_sent_at
      t.text :notification_error
      t.string :entitlement_id, limit: 64
      t.string :operator_identity_id, limit: 100
      t.string :operator_email, limit: 254
      t.bigint :operator_user_id
      t.integer :identity_version, null: false, default: 0
      t.integer :entitlement_version, null: false, default: 0
      t.string :plan_id, limit: 100
      t.datetime :issued_at
      t.datetime :paid_through_at
      t.datetime :grace_expires_at
      t.string :entitlement_digest, limit: 64
      t.jsonb :entitlement_payload, null: false, default: {}
      t.timestamps
    end

    add_index :discussion_bridge_operator_services, :installation_id, unique: true,
              name: "idx_discussion_bridge_operator_service_installation"
    add_index :discussion_bridge_operator_services, :enrollment_id, unique: true,
              name: "idx_discussion_bridge_operator_service_enrollment"
    add_index :discussion_bridge_operator_services, :operator_user_id
    add_index :discussion_bridge_operator_services, :entitlement_id, unique: true,
              where: "entitlement_id IS NOT NULL",
              name: "idx_discussion_bridge_operator_service_entitlement"

    create_table :discussion_bridge_operator_events do |t|
      t.references :operator_service, null: false,
                   foreign_key: { to_table: :discussion_bridge_operator_services }
      t.bigint :actor_user_id
      t.bigint :topic_id
      t.bigint :content_connection_id
      t.bigint :bridge_record_id
      t.string :event_type, null: false, limit: 100
      t.string :outcome, null: false, limit: 32
      t.jsonb :details, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :discussion_bridge_operator_events, :actor_user_id
    add_index :discussion_bridge_operator_events, :topic_id
    add_index :discussion_bridge_operator_events, :content_connection_id,
              name: "idx_discussion_bridge_operator_events_connection"
    add_index :discussion_bridge_operator_events, :bridge_record_id,
              name: "idx_discussion_bridge_operator_events_record"
    add_index :discussion_bridge_operator_events, :created_at
  end
end
