# frozen_string_literal: true

class AddPublicationPathToDiscussionBridgeContentConnections < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_content_connections,
               :include_source_in_published_url,
               :boolean,
               null: false,
               default: false
    add_column :discussion_bridge_content_connections,
               :publication_source_path,
               :string,
               limit: 120
  end
end
