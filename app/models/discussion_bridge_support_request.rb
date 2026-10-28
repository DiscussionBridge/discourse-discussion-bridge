# frozen_string_literal: true

class DiscussionBridgeSupportRequest < ActiveRecord::Base
  self.table_name = "discussion_bridge_support_requests"
  belongs_to :actor, class_name: "User", foreign_key: :actor_user_id, optional: true
  validates :status, inclusion: { in: %w[pending queued queue_unconfirmed sending submitted_to_mailer delivery_failed delivery_unconfirmed cancelled] }
end
