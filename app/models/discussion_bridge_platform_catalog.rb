# frozen_string_literal: true

class DiscussionBridgePlatformCatalog < ActiveRecord::Base
  self.table_name = "discussion_bridge_platform_catalogs"

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  has_many :segments,
           class_name: "DiscussionBridgePlatformCatalogSegment",
           foreign_key: :platform_catalog_id,
           dependent: :restrict_with_error

  validates :platform_profile, inclusion: { in: ::DiscussionBridge::ConnectionCapability::PROFILES }
  validates :catalog_revision, presence: true, length: { maximum: 255 },
                               uniqueness: { scope: %i[content_connection_id platform_profile] }
  validates :current, inclusion: { in: [true, false] }
end

# == Schema Information
#
# Table name: discussion_bridge_platform_catalogs
#
#  id                    :bigint           not null, primary key
#  catalog_revision      :string(255)      not null
#  current               :boolean          default(FALSE), not null
#  platform_profile      :string(32)       not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  content_connection_id :bigint           not null
#
# Indexes
#
#  idx_db_platform_catalogs_connection  (content_connection_id)
#  idx_db_platform_catalogs_current     (content_connection_id,platform_profile) UNIQUE WHERE (current = true)
#  idx_db_platform_catalogs_revision    (content_connection_id,platform_profile,catalog_revision) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
