# frozen_string_literal: true

require "digest"

class DiscussionBridgeCmsUrlReservation < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_url_reservations"

  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping", optional: true
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding", optional: true
  validate :exact_owner
  validates :state, inclusion: { in: %w[active prepared retired] }
  validates :canonical_url, :collision_key_sha256, presence: true
  validates :collision_key_sha256, length: { is: 64 }, uniqueness: true
  validate :canonical_collision_key_matches

  private

  def exact_owner
    valid = cms_mapping_id.nil? != content_binding_id.nil?
    valid &&= content_binding.role == "source" && content_binding.bridge_record.direction == "to_discourse" if content_binding_id
    errors.add(:base, "must identify one owned mapping or To source binding") unless valid
  end

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
