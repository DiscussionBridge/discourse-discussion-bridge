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

# == Schema Information
#
# Table name: discussion_bridge_source_authors
#
#  id                    :bigint           not null, primary key
#  display_name          :string(200)      not null
#  last_seen_at          :datetime         not null
#  profile_url           :text
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  content_connection_id :bigint           not null
#  discourse_user_id     :bigint
#  source_author_id      :string(255)      not null
#
# Indexes
#
#  idx_db_source_authors_connection_identity  (content_connection_id,source_author_id) UNIQUE
#  idx_db_source_authors_discourse_user       (discourse_user_id)
#
