# frozen_string_literal: true

class CreateDiscussionBridgePresentationUrlHistories < ActiveRecord::Migration[7.0]
  def change
    create_table :discussion_bridge_presentation_url_histories do |t|
      t.bigint :bridge_record_id, null: false
      t.bigint :content_binding_id, null: false
      t.bigint :verified_by_id, null: false
      t.text :old_canonical_url, null: false
      t.text :new_canonical_url, null: false
      t.string :old_canonical_url_digest, null: false, limit: 64
      t.integer :redirect_status, null: false
      t.datetime :verified_at, null: false
      t.timestamps
    end

    add_index :discussion_bridge_presentation_url_histories,
              :old_canonical_url_digest,
              unique: true,
              name: "idx_db_presentation_old_url"
    add_index :discussion_bridge_presentation_url_histories,
              :bridge_record_id,
              name: "idx_db_presentation_url_history_record"
    add_index :discussion_bridge_presentation_url_histories,
              :content_binding_id,
              name: "idx_db_presentation_url_history_binding"
  end
end
