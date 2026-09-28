# frozen_string_literal: true

class DiscussionBridgePlatformCatalogSegment < ActiveRecord::Base
  self.table_name = "discussion_bridge_platform_catalog_segments"

  belongs_to :platform_catalog, class_name: "DiscussionBridgePlatformCatalog"

  validates :segment_type, inclusion: { in: ::DiscussionBridge::PlatformCatalogProtocol::SEGMENT_TYPES },
                           uniqueness: { scope: :platform_catalog_id }
  validate :items_match_segment

  private

  def items_match_segment
    ::DiscussionBridge::PlatformCatalogProtocol.validate_items!(segment_type, items)
  rescue ::DiscussionBridge::AdapterRequestBoundary::Error
    errors.add(:items, "do not match the Adapter Protocol")
  end
end

# == Schema Information
#
# Table name: discussion_bridge_platform_catalog_segments
#
#  id                  :bigint           not null, primary key
#  items               :jsonb            not null
#  segment_type        :string(32)       not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  platform_catalog_id :bigint           not null
#
# Indexes
#
#  idx_db_catalog_segments_catalog  (platform_catalog_id)
#  idx_db_catalog_segments_unique   (platform_catalog_id,segment_type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (platform_catalog_id => discussion_bridge_platform_catalogs.id)
#
