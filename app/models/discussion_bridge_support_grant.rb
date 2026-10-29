# frozen_string_literal: true

class DiscussionBridgeSupportGrant < ActiveRecord::Base
  self.table_name = "discussion_bridge_support_grants"
  belongs_to :user, optional: true
  scope :active, -> { where(revoked_at: nil) }
end

# == Schema Information
#
# Table name: discussion_bridge_support_grants
#
#  id                 :bigint           not null, primary key
#  granted_at         :datetime         not null
#  revoked_at         :datetime
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  granted_by_user_id :bigint           not null
#  revoked_by_user_id :bigint
#  user_id            :bigint           not null
#
# Indexes
#
#  db_support_active_user  (user_id) UNIQUE WHERE (revoked_at IS NULL)
#
