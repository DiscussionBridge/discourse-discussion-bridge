# frozen_string_literal: true

class DiscussionBridgeCmsReadSnapshot < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_read_snapshots"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  has_many :items,
           class_name: "DiscussionBridgeCmsReadSnapshotItem",
           foreign_key: :cms_read_snapshot_id
  validates :kind, inclusion: { in: %w[mapping_inventory url_history record_inventory source_url_history] }
end

# == Schema Information
#
# Table name: discussion_bridge_cms_read_snapshots
#
#  id                    :bigint           not null, primary key
#  expires_at            :datetime         not null
#  invalidated_at        :datetime
#  item_count            :bigint           default(0), not null
#  kind                  :string(32)       not null
#  path_resource         :string(36)       default(""), not null
#  policy_revision       :string(128)      not null
#  publication_lane      :string(128)      not null
#  scope_signature       :string(64)       not null
#  created_at            :datetime         not null
#  content_connection_id :bigint           not null
#
# Indexes
#
#  idx_db_cms_read_snapshots_owner  (content_connection_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
