# frozen_string_literal: true

class DiscussionBridgeSourceSnapshotItem < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_snapshot_items"

  belongs_to :source_snapshot, class_name: "DiscussionBridgeSourceSnapshot"
  belongs_to :source_revision, class_name: "DiscussionBridgeSourceRevision"

  validates :ordinal,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: :source_snapshot_id }
  validates :source_revision_id, uniqueness: { scope: :source_snapshot_id }
end

# == Schema Information
#
# Table name: discussion_bridge_source_snapshot_items
#
#  id                 :bigint           not null, primary key
#  ordinal            :bigint           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  source_revision_id :bigint           not null
#  source_snapshot_id :bigint           not null
#
# Indexes
#
#  idx_db_source_snapshot_items_ordinal          (source_snapshot_id,ordinal) UNIQUE
#  idx_db_source_snapshot_items_revision         (source_revision_id)
#  idx_db_source_snapshot_items_snapshot         (source_snapshot_id)
#  idx_db_source_snapshot_items_unique_revision  (source_snapshot_id,source_revision_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (source_revision_id => discussion_bridge_source_revisions.id)
#  fk_rails_...  (source_snapshot_id => discussion_bridge_source_snapshots.id)
#
