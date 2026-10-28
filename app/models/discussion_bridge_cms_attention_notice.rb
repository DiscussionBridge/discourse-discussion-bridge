# frozen_string_literal: true

class DiscussionBridgeCmsAttentionNotice < ActiveRecord::Base
  belongs_to :cms_work, class_name: "DiscussionBridgeCmsWork"
  validates :attempt_cycle, :attention_snapshot, presence: true
  def readonly? = persisted?
end
