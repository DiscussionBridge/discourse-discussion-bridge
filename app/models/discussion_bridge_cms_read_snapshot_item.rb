# frozen_string_literal: true

class DiscussionBridgeCmsReadSnapshotItem < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_read_snapshot_items"
  belongs_to :cms_read_snapshot, class_name: "DiscussionBridgeCmsReadSnapshot"
end

# == Schema Information
#
# Table name: discussion_bridge_cms_read_snapshot_items
#
#  id                   :bigint           not null, primary key
#  ordinal              :bigint           not null
#  payload              :jsonb            not null
#  cms_read_snapshot_id :bigint           not null
#
# Indexes
#
#  idx_db_cms_read_snapshot_ordinal  (cms_read_snapshot_id,ordinal) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_read_snapshot_id => discussion_bridge_cms_read_snapshots.id)
#
