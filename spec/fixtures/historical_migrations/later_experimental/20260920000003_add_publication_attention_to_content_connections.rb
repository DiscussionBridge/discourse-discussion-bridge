# frozen_string_literal: true

class AddPublicationAttentionToContentConnections < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_content_connections,
               :publication_attention_fingerprint,
               :string,
               limit: 64
    add_column :discussion_bridge_content_connections,
               :publication_attention_notified_at,
               :datetime
  end
end
