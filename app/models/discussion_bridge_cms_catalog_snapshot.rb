# frozen_string_literal: true

class DiscussionBridgeCmsCatalogSnapshot < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_catalog_snapshots"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :catalog_upload, class_name: "DiscussionBridgeCmsCatalogUpload"
  has_many :entries, through: :catalog_upload
  has_many :cursors,
           class_name: "DiscussionBridgeCmsCatalogCursor",
           foreign_key: :catalog_snapshot_id

  validates :catalog_revision, :native_revision, :profile, :destination_origin, presence: true
  validates :kind, inclusion: { in: %w[authors taxonomy] }
  validates :total_items,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: 9_007_199_254_740_991,
            }
  validate :matches_owned_upload

  private

  def matches_owned_upload
    unless DiscussionBridge::CmsCatalogStore.snapshot_binding_valid?(self)
      errors.add(:catalog_upload, "must identify the same owned catalog metadata")
    end
  end
end
