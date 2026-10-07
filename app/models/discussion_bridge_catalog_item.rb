# frozen_string_literal: true

class DiscussionBridgeCatalogItem < ActiveRecord::Base
  self.table_name = "discussion_bridge_catalog_items"
  belongs_to :catalog_revision, class_name: "DiscussionBridgeCatalogRevision"

  def readonly?
    persisted?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_catalog_items
#
#  id                  :bigint           not null, primary key
#  segment_type        :string(32)       not null
#  value               :jsonb            not null
#  catalog_revision_id :bigint           not null
#  item_id             :string(255)      not null
#
# Indexes
#
#  idx_db_catalog_item_identity  (catalog_revision_id,segment_type,item_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (catalog_revision_id => discussion_bridge_catalog_revisions.id)
#
