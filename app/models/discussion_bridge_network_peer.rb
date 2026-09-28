# frozen_string_literal: true

class DiscussionBridgeNetworkPeer < ActiveRecord::Base
  self.table_name = "discussion_bridge_network_peers"

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :authorized_by, class_name: "User"
  has_many :network_replays,
           class_name: "DiscussionBridgeNetworkReplay",
           foreign_key: :network_peer_id,
           dependent: :restrict_with_error

  validates :name, :remote_forum_name, :remote_origin, :remote_connection_id,
            :remote_secret_ciphertext, presence: true
  validates :name, length: { maximum: 120 }
  validates :remote_forum_name, length: { maximum: 200 }
  validates :remote_forum_id,
            presence: true,
            format: { with: DiscussionBridge::DiscourseNetworkProtocol::FORUM_ID_PATTERN },
            uniqueness: { scope: :relationship }
  validates :remote_connection_id,
            format: { with: DiscussionBridge::AdapterRequestBoundary::CONNECTION_ID_PATTERN }
  validates :relationship,
            inclusion: { in: DiscussionBridge::DiscourseNetworkProtocol::RELATIONSHIPS }
  validate :remote_origin_is_canonical
  validate :connection_is_network_destination
  validate :remote_identity_is_not_local

  def remote_secret=(value)
    self.remote_secret_ciphertext = DiscussionBridge::NetworkSecret.encrypt(value)
  end

  def remote_secret
    DiscussionBridge::NetworkSecret.decrypt(remote_secret_ciphertext)
  end

  def operational?
    identity = DiscussionBridgeForumIdentity.current
    enabled && identity&.ready? && content_connection.enabled &&
      content_connection.network_enabled &&
      content_connection.network_peer_forum_id == remote_forum_id &&
      content_connection.network_relationship == relationship
  end

  private

  def remote_origin_is_canonical
    canonical = DiscussionBridge::CanonicalSource.origin(remote_origin.to_s)
    errors.add(:remote_origin, "must be a canonical HTTPS origin") unless canonical == remote_origin &&
      URI.parse(canonical).scheme == "https"
  rescue ArgumentError, URI::InvalidURIError
    errors.add(:remote_origin, "must be a canonical HTTPS origin")
  end

  def connection_is_network_destination
    return if content_connection && content_connection.platform == "discourse" &&
      content_connection.allows_direction?("to_discourse") && content_connection.network_enabled &&
      content_connection.network_peer_forum_id == remote_forum_id &&
      content_connection.network_relationship == relationship &&
      Array(content_connection.destination_policies).any? do |policy|
        policy.stringify_keys["profile"] == "discourse_as_publisher"
      end

    errors.add(:content_connection, "must be an enabled Discourse network destination")
  end

  def remote_identity_is_not_local
    identity = DiscussionBridgeForumIdentity.current
    return unless identity&.reserved_forum_id?(remote_forum_id)

    errors.add(:remote_forum_id, "cannot use the current or a retired local forum identity")
  end
end

# == Schema Information
#
# Table name: discussion_bridge_network_peers
#
#  id                       :bigint           not null, primary key
#  authorized_at            :datetime         not null
#  disabled_at              :datetime
#  enabled                  :boolean          default(FALSE), not null
#  name                     :string(120)      not null
#  relationship             :string(32)       not null
#  remote_forum_name        :string(200)      not null
#  remote_origin            :string(2048)     not null
#  remote_secret_ciphertext :text             not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  authorized_by_id         :bigint           not null
#  content_connection_id    :bigint           not null
#  remote_connection_id     :string(64)       not null
#  remote_forum_id          :string(36)       not null
#
# Indexes
#
#  idx_db_network_peers_connection        (content_connection_id) UNIQUE
#  idx_db_network_peers_remote_direction  (remote_forum_id,relationship) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (authorized_by_id => users.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
