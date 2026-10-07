# frozen_string_literal: true

class DiscussionBridgePublicationRetry < ActiveRecord::Base
  self.table_name = "discussion_bridge_publication_retries"
  belongs_to :publication_work, class_name: "DiscussionBridgePublicationWork"
  belongs_to :publication_failure, class_name: "DiscussionBridgePublicationFailure"
  belongs_to :actor, class_name: "User"

  def readonly?
    persisted?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_publication_retries
#
#  id                     :bigint           not null, primary key
#  evidence_digest        :string(64)       not null
#  performed_at           :datetime         not null
#  performed_at_raw       :string(255)      not null
#  prior_generation       :integer          not null
#  receipt_digest         :string(64)
#  request                :jsonb            not null
#  request_digest         :string(64)       not null
#  response               :jsonb            not null
#  response_digest        :string(64)       not null
#  retry_generation       :integer          not null
#  actor_id               :bigint           not null
#  publication_failure_id :bigint           not null
#  publication_work_id    :bigint           not null
#
# Indexes
#
#  idx_db_retry_generation  (publication_work_id,prior_generation) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (actor_id => users.id)
#  fk_rails_...  (publication_failure_id => discussion_bridge_publication_failures.id)
#  fk_rails_...  (publication_work_id => discussion_bridge_publication_works.id)
#
