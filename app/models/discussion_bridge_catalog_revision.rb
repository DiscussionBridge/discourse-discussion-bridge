# frozen_string_literal: true

class DiscussionBridgeCatalogRevision < ActiveRecord::Base
  self.table_name = "discussion_bridge_catalog_revisions"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  has_many :catalog_items, class_name: "DiscussionBridgeCatalogItem", foreign_key: :catalog_revision_id

  def readonly?
    persisted?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_catalog_revisions
#
#  id                    :bigint           not null, primary key
#  platform_profile      :string(32)       not null
#  created_at            :datetime         not null
#  content_connection_id :bigint           not null
#  public_id             :string(255)      not null
#
# Indexes
#
#  idx_db_catalog_revision_current  (content_connection_id,platform_profile,id)
#  idx_db_catalog_revision_public   (public_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
