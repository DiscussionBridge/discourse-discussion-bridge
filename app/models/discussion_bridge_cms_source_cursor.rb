# frozen_string_literal: true

class DiscussionBridgeCmsSourceCursor < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_cursors"
  belongs_to :cms_source_stream, class_name: "DiscussionBridgeCmsSourceStream"
  belongs_to :snapshot_root, class_name: "DiscussionBridgeCmsSourceCursor", optional: true
  has_many :snapshot_items,
           class_name: "DiscussionBridgeCmsSourceSnapshotItem",
           foreign_key: :snapshot_root_id
  validates :kind, inclusion: { in: %w[initial changes checkpoint] }
end
