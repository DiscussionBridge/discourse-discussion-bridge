# frozen_string_literal: true

class DiscussionBridgeSourceAuthor < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_authors"

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :discourse_user, class_name: "User", optional: true

  validates :source_author_id, :display_name, :last_seen_at, presence: true
  validates :source_author_id,
            length: { maximum: 255 },
            uniqueness: { scope: :content_connection_id }
  validates :display_name, length: { maximum: 200 }
  validate :discourse_user_is_usable

  private

  def discourse_user_is_usable
    return if discourse_user.nil?
    return if discourse_user.active? && !discourse_user.staged? && !discourse_user.suspended? &&
      !discourse_user.silenced? && discourse_user.id != Discourse::SYSTEM_USER_ID

    errors.add(:discourse_user, "must be an active non-system Discourse user")
  end
end
