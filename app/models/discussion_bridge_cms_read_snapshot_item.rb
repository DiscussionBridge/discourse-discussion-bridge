# frozen_string_literal: true

class DiscussionBridgeCmsReadSnapshotItem < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_read_snapshot_items"
  belongs_to :cms_read_snapshot, class_name: "DiscussionBridgeCmsReadSnapshot"
end
