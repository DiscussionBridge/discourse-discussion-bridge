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
