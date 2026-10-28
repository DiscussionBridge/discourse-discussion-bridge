# frozen_string_literal: true

class DiscussionBridgeCmsCatalogCursor < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_catalog_cursors"
  belongs_to :catalog_snapshot, class_name: "DiscussionBridgeCmsCatalogSnapshot"
  validates :scope_signature, :token_digest, :expires_at, presence: true
  validates :position,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: 9_007_199_254_740_991,
            }
end
