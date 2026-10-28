# frozen_string_literal: true

class DiscussionBridgeCmsReadSnapshot < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_read_snapshots"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  has_many :items,
           class_name: "DiscussionBridgeCmsReadSnapshotItem",
           foreign_key: :cms_read_snapshot_id
  validates :kind, inclusion: { in: %w[mapping_inventory url_history record_inventory source_url_history] }
end
