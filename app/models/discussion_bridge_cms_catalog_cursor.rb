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

# == Schema Information
#
# Table name: discussion_bridge_cms_catalog_cursors
#
#  id                  :bigint           not null, primary key
#  expires_at          :datetime         not null
#  invalidated_at      :datetime
#  page_body           :jsonb
#  position            :bigint           not null
#  scope_signature     :string(64)       not null
#  token_digest        :string(64)       not null
#  created_at          :datetime         not null
#  catalog_snapshot_id :bigint           not null
#
# Indexes
#
#  idx_db_cms_catalog_cursor_token  (token_digest) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (catalog_snapshot_id => discussion_bridge_cms_catalog_snapshots.id)
#
