# frozen_string_literal: true

class DiscussionBridgeSourceSnapshot < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_snapshots"

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  has_many :snapshot_items,
           class_name: "DiscussionBridgeSourceSnapshotItem",
           foreign_key: :source_snapshot_id,
           dependent: :restrict_with_error

  validates :snapshot_id, :policy_revision, :last_read_at, :expires_at, presence: true
  validates :snapshot_id,
            format: { with: DiscussionBridge::SourcePublicationProtocol::SNAPSHOT_ID_PATTERN },
            uniqueness: true
  validates :policy_revision, length: { maximum: 255 }
end

# == Schema Information
#
# Table name: discussion_bridge_source_snapshots
#
#  id                    :bigint           not null, primary key
#  completed_at          :datetime
#  expires_at            :datetime         not null
#  last_read_at          :datetime         not null
#  policy_revision       :string(255)      not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  content_connection_id :bigint           not null
#  snapshot_id           :string(36)       not null
#
# Indexes
#
#  idx_db_source_snapshots_connection  (content_connection_id)
#  idx_db_source_snapshots_public_id   (snapshot_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
