# frozen_string_literal: true

class DiscussionBridgeCmsReadCursor < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_read_cursors"
  belongs_to :cms_read_snapshot, class_name: "DiscussionBridgeCmsReadSnapshot"
end
