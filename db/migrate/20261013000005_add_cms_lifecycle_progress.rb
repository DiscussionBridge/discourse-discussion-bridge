# frozen_string_literal: true

class AddCmsLifecycleProgress < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_cms_source_streams,
               :scan_phase,
               :string,
               limit: 16,
               null: false,
               default: "topics"
    add_column :discussion_bridge_cms_source_streams,
               :scan_high_intent_id,
               :bigint
    add_column :discussion_bridge_cms_source_streams,
               :scan_last_intent_id,
               :bigint,
               null: false,
               default: 0
    add_column :discussion_bridge_cms_source_streams,
               :lifecycle_error_code,
               :string,
               limit: 64
    add_column :discussion_bridge_cms_source_streams,
               :lifecycle_failed_at,
               :datetime
  end
end
