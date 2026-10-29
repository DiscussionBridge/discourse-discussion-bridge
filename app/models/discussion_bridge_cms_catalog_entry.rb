# frozen_string_literal: true

class DiscussionBridgeCmsCatalogEntry < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_catalog_entries"
  belongs_to :catalog_upload, class_name: "DiscussionBridgeCmsCatalogUpload"
  validates :entry_id, :entry_id_sha256, :payload, presence: true
  validates :ordinal,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: 9_007_199_254_740_991,
            }
end

# == Schema Information
#
# Table name: discussion_bridge_cms_catalog_entries
#
#  id                :bigint           not null, primary key
#  entry_id_sha256   :string(64)       not null
#  ordinal           :bigint           not null
#  payload           :jsonb            not null
#  created_at        :datetime         not null
#  catalog_upload_id :bigint           not null
#  entry_id          :text             not null
#
# Indexes
#
#  idx_db_cms_catalog_entry_identity  (catalog_upload_id,entry_id_sha256) UNIQUE
#  idx_db_cms_catalog_entry_order     (catalog_upload_id,ordinal) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (catalog_upload_id => discussion_bridge_cms_catalog_uploads.id)
#
