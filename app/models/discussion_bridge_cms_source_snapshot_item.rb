# frozen_string_literal: true

class DiscussionBridgeCmsSourceSnapshotItem < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_snapshot_items"
  belongs_to :snapshot_root, class_name: "DiscussionBridgeCmsSourceCursor"
  belongs_to :cms_source_event, class_name: "DiscussionBridgeCmsSourceEvent"
end
