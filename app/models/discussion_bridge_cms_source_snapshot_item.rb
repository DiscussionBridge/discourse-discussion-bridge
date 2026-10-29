# frozen_string_literal: true

class DiscussionBridgeCmsSourceSnapshotItem < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_snapshot_items"
  belongs_to :snapshot_root, class_name: "DiscussionBridgeCmsSourceCursor"
  belongs_to :cms_source_event, class_name: "DiscussionBridgeCmsSourceEvent"
end

# == Schema Information
#
# Table name: discussion_bridge_cms_source_snapshot_items
#
#  id                  :bigint           not null, primary key
#  ordinal             :bigint           not null
#  cms_source_event_id :bigint           not null
#  snapshot_root_id    :bigint           not null
#
# Indexes
#
#  idx_db_cms_snapshot_root_ordinal  (snapshot_root_id,ordinal) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_source_event_id => discussion_bridge_cms_source_events.id)
#  fk_rails_...  (snapshot_root_id => discussion_bridge_cms_source_cursors.id)
#
