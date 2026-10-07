# frozen_string_literal: true

class DiscussionBridgePublicationFailure < ActiveRecord::Base
  self.table_name = "discussion_bridge_publication_failures"
  belongs_to :work_issue, class_name: "DiscussionBridgeWorkIssue"

  def readonly?
    persisted?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_publication_failures
#
#  id              :bigint           not null, primary key
#  from_state      :string(32)       not null
#  next_retry_at   :datetime
#  receipt_digest  :string(64)
#  received_at     :datetime         not null
#  received_at_raw :string(255)
#  request         :jsonb            not null
#  request_digest  :string(64)       not null
#  resulting_state :string(32)       not null
#  work_issue_id   :bigint           not null
#
# Indexes
#
#  idx_db_failure_issue  (work_issue_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (work_issue_id => discussion_bridge_work_issues.id)
#
