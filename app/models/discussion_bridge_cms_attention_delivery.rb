# frozen_string_literal: true

class DiscussionBridgeCmsAttentionDelivery < ActiveRecord::Base
  belongs_to :notice, class_name: "DiscussionBridgeCmsAttentionNotice"
  belongs_to :user
end
