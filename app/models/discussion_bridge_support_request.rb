# frozen_string_literal: true

class DiscussionBridgeSupportRequest < ActiveRecord::Base
  self.table_name = "discussion_bridge_support_requests"
  belongs_to :actor, class_name: "User", foreign_key: :actor_user_id, optional: true
  validates :status, inclusion: { in: %w[pending queued queue_unconfirmed sending submitted_to_mailer delivery_failed delivery_unconfirmed cancelled] }
end

# == Schema Information
#
# Table name: discussion_bridge_support_requests
#
#  id                  :bigint           not null, primary key
#  contact_email       :string(320)      not null
#  failure_code        :string
#  forum_url           :text             not null
#  payload_sha256      :string(64)       not null
#  plugin_version      :string           not null
#  problem             :text             not null
#  request_destination :string(320)      not null
#  status              :string           not null
#  submitted_at        :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  actor_user_id       :bigint           not null
#  email_log_id        :bigint
#  request_id          :string(36)       not null
#
# Indexes
#
#  db_support_request_uuid  (request_id) UNIQUE
#
