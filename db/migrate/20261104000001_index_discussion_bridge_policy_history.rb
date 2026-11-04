# frozen_string_literal: true

class IndexDiscussionBridgePolicyHistory < ActiveRecord::Migration[7.0]
  def change
    add_index :discussion_bridge_cms_configuration_events,
              %i[content_connection_id policy_revision],
              name: "idx_db_cms_policy_revision"
    add_index :discussion_bridge_cms_configuration_events,
              %i[content_connection_id id],
              name: "idx_db_cms_policy_history_order"
  end
end
