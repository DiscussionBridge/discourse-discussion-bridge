# frozen_string_literal: true

class DiscussionBridgeCmsCatalogPage < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_catalog_pages"
  belongs_to :catalog_upload, class_name: "DiscussionBridgeCmsCatalogUpload"
  validates :page,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: 9_007_199_254_740_991,
            }
end

# == Schema Information
#
# Table name: discussion_bridge_cms_catalog_pages
#
#  id                :bigint           not null, primary key
#  acknowledgement   :jsonb            not null
#  entries           :jsonb            not null
#  page              :bigint           not null
#  created_at        :datetime         not null
#  catalog_upload_id :bigint           not null
#
# Indexes
#
#  idx_db_cms_catalog_page_identity  (catalog_upload_id,page) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (catalog_upload_id => discussion_bridge_cms_catalog_uploads.id)
#
