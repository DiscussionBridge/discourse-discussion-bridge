# frozen_string_literal: true

class CreateDiscussionBridgeAuditEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_audit_events do |t|
      t.string :correlation_id
      t.string :connection_id, null: false
      t.string :adapter_id
      t.string :source_identity_digest, null: false, limit: 64
      t.bigint :topic_id
      t.bigint :effective_actor_id
      t.string :outcome, null: false
      t.string :reason, null: false
      t.jsonb :requested_state, null: false, default: {}
      t.jsonb :effective_state, null: false, default: {}
      t.timestamps
    end

    add_index :discussion_bridge_audit_events, :correlation_id
    add_index :discussion_bridge_audit_events, :source_identity_digest,
              name: "idx_discussion_bridge_audits_source"
    add_index :discussion_bridge_audit_events, :topic_id
    add_index :discussion_bridge_audit_events, :created_at
  end
end
