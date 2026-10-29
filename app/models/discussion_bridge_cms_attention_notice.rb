# frozen_string_literal: true

class DiscussionBridgeCmsAttentionNotice < ActiveRecord::Base
  belongs_to :cms_work, class_name: "DiscussionBridgeCmsWork"
  validates :attempt_cycle, :attention_snapshot, presence: true
  def readonly? = persisted?
end

# == Schema Information
#
# Table name: discussion_bridge_cms_attention_notices
#
#  id                    :bigint           not null, primary key
#  attempt_cycle         :uuid             not null
#  attention_snapshot    :jsonb            not null
#  created_at            :datetime         not null
#  cms_work_id           :bigint           not null
#  content_connection_id :bigint           not null
#
# Indexes
#
#  idx_db_attention_notice_occurrence  (cms_work_id,attempt_cycle) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_work_id => discussion_bridge_cms_work.id)
#
