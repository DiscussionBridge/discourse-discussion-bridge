# frozen_string_literal: true

class DiscussionBridgeSupportGrant < ActiveRecord::Base
  self.table_name = "discussion_bridge_support_grants"
  belongs_to :user, optional: true
  scope :active, -> { where(revoked_at: nil) }
end
