# frozen_string_literal: true

class DiscussionBridgeCmsAttentionDelivery < ActiveRecord::Base
  belongs_to :notice, class_name: "DiscussionBridgeCmsAttentionNotice"
  belongs_to :user
end

# == Schema Information
#
# Table name: discussion_bridge_cms_attention_deliveries
#
#  id              :bigint           not null, primary key
#  delivered_at    :datetime
#  skipped_at      :datetime
#  notice_id       :bigint           not null
#  notification_id :bigint
#  user_id         :bigint           not null
#
# Indexes
#
#  idx_db_attention_notice_recipient  (notice_id,user_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (notice_id => discussion_bridge_cms_attention_notices.id)
#
