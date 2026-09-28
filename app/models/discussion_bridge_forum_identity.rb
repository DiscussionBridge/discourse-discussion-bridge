# frozen_string_literal: true

class DiscussionBridgeForumIdentity < ActiveRecord::Base
  self.table_name = "discussion_bridge_forum_identities"

  SINGLETON_KEY = "current"

  belongs_to :changed_by, class_name: "User"

  validates :singleton_key, inclusion: { in: [SINGLETON_KEY] }, uniqueness: true
  validates :forum_id,
            presence: true,
            uniqueness: true,
            format: { with: DiscussionBridge::DiscourseNetworkProtocol::FORUM_ID_PATTERN }
  validates :site_origin, presence: true, length: { maximum: 2_048 }
  validate :retired_forum_ids_are_valid

  def self.current
    find_by(singleton_key: SINGLETON_KEY)
  end

  def self.enable!(actor:)
    transaction do
      identity = lock.find_by(singleton_key: SINGLETON_KEY)
      origin = DiscussionBridge::CanonicalSource.origin(Discourse.base_url)
      if identity
        raise ArgumentError, "forum identity requires explicit rotation after a clone" unless
          identity.site_origin == origin

        identity.update!(enabled: true, enabled_at: Time.zone.now, disabled_at: nil, changed_by: actor)
        identity
      else
        create!(
          singleton_key: SINGLETON_KEY,
          forum_id: DiscussionBridge::DiscourseNetworkProtocol.forum_id,
          site_origin: origin,
          enabled: true,
          enabled_at: Time.zone.now,
          changed_by: actor,
        )
      end
    end
  end

  def disable!(actor:)
    update!(enabled: false, disabled_at: Time.zone.now, changed_by: actor)
  end

  def rotate!(actor:)
    self.class.transaction do
      lock!
      old_id = forum_id
      update!(
        forum_id: DiscussionBridge::DiscourseNetworkProtocol.forum_id,
        site_origin: DiscussionBridge::CanonicalSource.origin(Discourse.base_url),
        enabled: false,
        retired_forum_ids: (Array(retired_forum_ids) + [old_id]).uniq,
        changed_by: actor,
        enabled_at: nil,
        disabled_at: Time.zone.now,
        rotated_at: Time.zone.now,
      )
      DiscussionBridgeNetworkPeer.where(enabled: true).update_all(
        enabled: false,
        disabled_at: Time.zone.now,
        updated_at: Time.zone.now,
      )
      DiscussionBridgeContentConnection.where(network_enabled: true).update_all(
        network_enabled: false,
        updated_at: Time.zone.now,
      )
      self
    end
  end

  def ready?
    enabled && site_origin == DiscussionBridge::CanonicalSource.origin(Discourse.base_url)
  rescue ArgumentError
    false
  end

  def reserved_forum_id?(value)
    forum_id == value || Array(retired_forum_ids).include?(value)
  end

  private

  def retired_forum_ids_are_valid
    values = Array(retired_forum_ids)
    unless retired_forum_ids.is_a?(Array) && values.uniq == values &&
        values.all? { |value| DiscussionBridge::DiscourseNetworkProtocol::FORUM_ID_PATTERN.match?(value.to_s) }
      errors.add(:retired_forum_ids, "must contain unique prior forum identities")
    end
    errors.add(:retired_forum_ids, "cannot contain the current forum identity") if values.include?(forum_id)
  end
end

# == Schema Information
#
# Table name: discussion_bridge_forum_identities
#
#  id                :bigint           not null, primary key
#  disabled_at       :datetime
#  enabled           :boolean          default(FALSE), not null
#  enabled_at        :datetime
#  retired_forum_ids :jsonb            not null
#  rotated_at        :datetime
#  singleton_key     :string(16)       default("current"), not null
#  site_origin       :string(2048)     not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  changed_by_id     :bigint           not null
#  forum_id          :string(36)       not null
#
# Indexes
#
#  idx_db_forum_identity_public_id  (forum_id) UNIQUE
#  idx_db_forum_identity_singleton  (singleton_key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (changed_by_id => users.id)
#
