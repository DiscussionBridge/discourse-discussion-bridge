# frozen_string_literal: true

class DiscussionBridgePublicationReceipt < ActiveRecord::Base
  self.table_name = "discussion_bridge_publication_receipts"
  belongs_to :work_issue, class_name: "DiscussionBridgeWorkIssue"

  def readonly?
    persisted?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_publication_receipts
#
#  id              :bigint           not null, primary key
#  received_at     :datetime         not null
#  request         :jsonb            not null
#  request_digest  :string(64)       not null
#  response        :jsonb            not null
#  response_digest :string(64)       not null
#  stage           :string(16)       not null
#  work_issue_id   :bigint           not null
#
# Indexes
#
#  idx_db_receipt_issue_stage  (work_issue_id,stage) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (work_issue_id => discussion_bridge_work_issues.id)
#
