# frozen_string_literal: true

class AddTopicTocToDiscussionBridgeContentConnections < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_content_connections,
               :generate_topic_toc,
               :boolean,
               null: false,
               default: false
  end
end
