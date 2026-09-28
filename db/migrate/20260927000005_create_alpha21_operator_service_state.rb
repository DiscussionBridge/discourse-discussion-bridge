# frozen_string_literal: true

class CreateAlpha21OperatorServiceState < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_operator_enrollments do |t|
      t.string :singleton_key, null: false, default: "current", limit: 16
      t.boolean :enabled, null: false, default: false
      t.string :forum_id, null: false, limit: 36
      t.string :provider_id, null: false, limit: 36
      t.string :provider_name, null: false, limit: 200
      t.string :state, null: false, default: "pending_enrollment", limit: 32
      t.string :current_entitlement_id, limit: 36
      t.bigint :operator_user_id
      t.datetime :disabled_at
      t.timestamps
    end
    add_index :discussion_bridge_operator_enrollments, :singleton_key,
              unique: true, name: "idx_db_operator_enrollment_singleton"
    add_index :discussion_bridge_operator_enrollments, :forum_id,
              unique: true, name: "idx_db_operator_enrollment_forum"
    add_index :discussion_bridge_operator_enrollments, :operator_user_id,
              name: "idx_db_operator_enrollment_user"

    create_table :discussion_bridge_operator_trusted_keys do |t|
      t.string :issuer_id, null: false, limit: 36
      t.string :key_id, null: false, limit: 200
      t.string :public_key_base64url, null: false, limit: 64
      t.boolean :may_issue, null: false, default: true
      t.datetime :retire_at
      t.datetime :revoked_at
      t.bigint :enrolled_by_id, null: false
      t.datetime :enrolled_at, null: false
      t.timestamps
    end
    add_index :discussion_bridge_operator_trusted_keys, %i[issuer_id key_id],
              unique: true, name: "idx_db_operator_trusted_keys_identity"

    create_table :discussion_bridge_operator_entitlements do |t|
      t.string :entitlement_id, null: false, limit: 36
      t.string :provider_id, null: false, limit: 36
      t.string :provider_name, null: false, limit: 200
      t.string :forum_id, null: false, limit: 36
      t.string :issuer_id, null: false, limit: 36
      t.string :key_id, null: false, limit: 200
      t.integer :entitlement_version, null: false
      t.jsonb :scopes, null: false, default: []
      t.string :signature, null: false, limit: 100
      t.string :payload_sha256, null: false, limit: 64
      t.jsonb :payload, null: false, default: {}
      t.string :state, null: false, limit: 32
      t.datetime :issued_at, null: false
      t.datetime :not_before, null: false
      t.datetime :expires_at, null: false
      t.datetime :grace_until, null: false
      t.datetime :activated_at, null: false
      t.datetime :revoked_at
      t.string :replaced_by_entitlement_id, limit: 36
      t.bigint :enrolled_by_id, null: false
      t.timestamps
    end
    add_index :discussion_bridge_operator_entitlements, :entitlement_id,
              unique: true, name: "idx_db_operator_entitlements_identity"
    add_index :discussion_bridge_operator_entitlements, %i[forum_id state],
              name: "idx_db_operator_entitlements_forum_state"
    add_index :discussion_bridge_operator_entitlements, %i[issuer_id key_id],
              name: "idx_db_operator_entitlements_key"

    create_table :discussion_bridge_operator_approvals do |t|
      t.string :approval_id, null: false, limit: 200
      t.string :forum_id, null: false, limit: 36
      t.string :provider_id, null: false, limit: 36
      t.string :entitlement_id, null: false, limit: 36
      t.string :scope, null: false, limit: 80
      t.string :operation_sha256, null: false, limit: 64
      t.bigint :approved_by_id, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :discussion_bridge_operator_approvals, :approval_id,
              unique: true, name: "idx_db_operator_approvals_identity"
    add_index :discussion_bridge_operator_approvals,
              %i[forum_id provider_id entitlement_id scope operation_sha256],
              name: "idx_db_operator_approvals_binding"

    create_table :discussion_bridge_operator_audit_records do |t|
      t.string :event_id, null: false, limit: 36
      t.datetime :occurred_at, null: false
      t.string :forum_id, null: false, limit: 36
      t.string :provider_id, null: false, limit: 36
      t.string :entitlement_id, limit: 36
      t.string :actor, null: false, limit: 200
      t.string :scope, null: false, limit: 80
      t.string :action, null: false, limit: 100
      t.string :target_type, null: false, limit: 100
      t.string :target_id, null: false, limit: 200
      t.string :operation_sha256, null: false, limit: 64
      t.string :customer_approval_id, limit: 200
      t.string :outcome, null: false, limit: 32
      t.timestamps
    end
    add_index :discussion_bridge_operator_audit_records, :event_id,
              unique: true, name: "idx_db_operator_audit_event"
    add_index :discussion_bridge_operator_audit_records, %i[forum_id occurred_at],
              name: "idx_db_operator_audit_forum_time"
    add_index :discussion_bridge_operator_audit_records, :entitlement_id,
              name: "idx_db_operator_audit_entitlement"
  end
end
