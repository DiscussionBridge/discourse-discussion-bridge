# frozen_string_literal: true

class DiscussionBridgeWorkIssue < ActiveRecord::Base
  self.table_name = "discussion_bridge_work_issues"
  belongs_to :publication_work, class_name: "DiscussionBridgePublicationWork"

  def readonly?
    persisted?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_work_issues
#
#  id                  :bigint           not null, primary key
#  claimed_at          :datetime         not null
#  work                :jsonb            not null
#  publication_work_id :bigint           not null
#  worker_id           :string(200)      not null
#
# Foreign Keys
#
#  fk_rails_...  (publication_work_id => discussion_bridge_publication_works.id)
#
