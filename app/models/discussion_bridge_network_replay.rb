# frozen_string_literal: true

class DiscussionBridgeNetworkReplay < ActiveRecord::Base
  self.table_name = "discussion_bridge_network_replays"

  belongs_to :network_peer, class_name: "DiscussionBridgeNetworkPeer"

  validates :origin_forum_id,
            presence: true,
            format: { with: DiscussionBridge::DiscourseNetworkProtocol::FORUM_ID_PATTERN }
  validates :operation_id,
            presence: true,
            format: { with: DiscussionBridge::DiscourseNetworkProtocol::OPERATION_ID_PATTERN },
            uniqueness: { scope: :origin_forum_id }
  validates :immutable_sha256,
            presence: true,
            length: { is: 64 },
            format: { with: DiscussionBridge::DiscourseNetworkProtocol::SHA256_PATTERN }
  validates :correlation_id, presence: true, length: { maximum: 200 }
  validates :expires_at, presence: true
end

# == Schema Information
#
# Table name: discussion_bridge_network_replays
#
#  id                  :bigint           not null, primary key
#  expires_at          :datetime         not null
#  immutable_operation :jsonb            not null
#  immutable_sha256    :string(64)       not null
#  retained_result     :jsonb            not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  correlation_id      :string(200)      not null
#  network_peer_id     :bigint           not null
#  operation_id        :string(36)       not null
#  origin_forum_id     :string(36)       not null
#
# Indexes
#
#  idx_db_network_replays_expiry     (expires_at)
#  idx_db_network_replays_operation  (origin_forum_id,operation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (network_peer_id => discussion_bridge_network_peers.id)
#
