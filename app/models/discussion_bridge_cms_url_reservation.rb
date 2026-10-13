# frozen_string_literal: true

require "digest"

class DiscussionBridgeCmsUrlReservation < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_url_reservations"

  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping"
  validates :state, inclusion: { in: %w[active prepared retired] }
  validates :canonical_url, :collision_key_sha256, presence: true
  validates :collision_key_sha256, length: { is: 64 }, uniqueness: true
  validate :canonical_collision_key_matches

  private

  def canonical_collision_key_matches
    DiscussionBridge::CmsProtocol.validate!("Url", canonical_url)
    expected =
      Digest::SHA256.hexdigest(
        DiscussionBridge::CmsProtocol.url_key(canonical_url)
      )
    unless collision_key_sha256 == expected
      errors.add(:collision_key_sha256, "does not match URL")
    end
  rescue DiscussionBridge::CmsProtocol::Error
    errors.add(:canonical_url, "is invalid")
  end
end
