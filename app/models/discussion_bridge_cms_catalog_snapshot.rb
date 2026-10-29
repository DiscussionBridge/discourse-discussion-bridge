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

# == Schema Information
#
# Table name: discussion_bridge_cms_catalog_snapshots
#
#  id                    :bigint           not null, primary key
#  active                :boolean          default(FALSE), not null
#  catalog_revision      :string(128)      not null
#  destination_origin    :text             not null
#  kind                  :string(16)       not null
#  native_revision       :string(128)      not null
#  profile               :string(32)       not null
#  publication_lane      :string(64)       not null
#  total_items           :bigint           not null
#  created_at            :datetime         not null
#  catalog_upload_id     :bigint           not null
#  content_connection_id :bigint           not null
#
# Indexes
#
#  idx_db_cms_catalog_snapshot_active    (content_connection_id,kind,publication_lane) UNIQUE WHERE (active = true)
#  idx_db_cms_catalog_snapshot_revision  (catalog_revision) UNIQUE
#  idx_db_cms_catalog_snapshot_upload    (catalog_upload_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (catalog_upload_id => discussion_bridge_cms_catalog_uploads.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
