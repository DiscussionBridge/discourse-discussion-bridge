# frozen_string_literal: true

class AddProviderToDiscussionBridgeOperatorServices < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_operator_services, :provider_id, :string,
               null: false, default: "discussionbridge", limit: 64
    add_index :discussion_bridge_operator_services, :provider_id,
              name: "idx_discussion_bridge_operator_service_provider"
  end
end
