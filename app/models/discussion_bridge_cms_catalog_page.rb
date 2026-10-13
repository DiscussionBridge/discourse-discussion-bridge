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
