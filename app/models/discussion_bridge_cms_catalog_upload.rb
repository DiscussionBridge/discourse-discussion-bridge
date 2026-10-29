# frozen_string_literal: true

class DiscussionBridgeCmsCatalogUpload < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_catalog_uploads"

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  has_many :pages, class_name: "DiscussionBridgeCmsCatalogPage", foreign_key: :catalog_upload_id
  has_many :entries, class_name: "DiscussionBridgeCmsCatalogEntry", foreign_key: :catalog_upload_id
  has_one :snapshot,
          class_name: "DiscussionBridgeCmsCatalogSnapshot",
          foreign_key: :catalog_upload_id

  validates :upload_id,
            :profile,
            :destination_origin,
            :scope_signature,
            :native_revision,
            :expires_at,
            presence: true
  validates :kind, inclusion: { in: %w[authors taxonomy] }
  validates :state, inclusion: { in: %w[open finalized] }
  validates :total_items,
            :received_items,
            :next_page,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: 9_007_199_254_740_991,
            }
end

# == Schema Information
#
# Table name: discussion_bridge_cms_catalog_uploads
#
#  id                    :bigint           not null, primary key
#  destination_origin    :text             not null
#  expires_at            :datetime         not null
#  finalized_response    :jsonb
#  invalidated_at        :datetime
#  kind                  :string(16)       not null
#  native_revision       :string(128)      not null
#  next_page             :bigint           default(0), not null
#  profile               :string(32)       not null
#  publication_lane      :string(64)       not null
#  received_items        :bigint           default(0), not null
#  scope_signature       :string(64)       not null
#  state                 :string(16)       default("open"), not null
#  total_items           :bigint           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  content_connection_id :bigint           not null
#  upload_id             :uuid             not null
#
# Indexes
#
#  idx_db_cms_catalog_upload_owner  (content_connection_id,kind,publication_lane)
#  idx_db_cms_catalog_upload_uuid   (upload_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
