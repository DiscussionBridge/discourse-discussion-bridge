# frozen_string_literal: true

class DiscussionBridgeCmsWork < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_work"
  TERMINAL_STATES = %w[verified cancelled superseded].freeze
  LIVE_STATES = %w[leased synchronized deployed].freeze
  UNCOMPLETED_STATES = %w[pending leased synchronized deployed retry_wait attention].freeze

  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping"
  validates :work_id, :policy_revision, :attempt_cycle, presence: true
  validates :action, inclusion: { in: %w[publish_revision withdraw] }
  validates :state, inclusion: { in: UNCOMPLETED_STATES + TERMINAL_STATES }
  validates :attempt, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                    less_than_or_equal_to: 3 }
  validate :revision_matches_action

  private

  def revision_matches_action
    valid = action == "withdraw" ? source_revision.nil? : source_revision.present?
    errors.add(:source_revision, "does not match action") unless valid
  end
end

# == Schema Information
#
# Table name: discussion_bridge_cms_work
#
#  id                :bigint           not null, primary key
#  action            :string(32)       not null
#  attempt           :integer          default(0), not null
#  attempt_cycle     :uuid             not null
#  failure_detail    :jsonb
#  last_failure_code :string(64)
#  lease_expires_at  :datetime
#  lease_generation  :bigint           default(0), not null
#  lease_verifier    :string(64)
#  policy_revision   :string(128)      not null
#  retry_at          :datetime
#  same_intent_hold  :boolean          default(FALSE), not null
#  source_revision   :string(128)
#  source_snapshot   :jsonb
#  state             :string(32)       default("pending"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  cms_mapping_id    :bigint           not null
#  retry_of_work_id  :bigint
#  work_id           :uuid             not null
#
# Indexes
#
#  idx_db_cms_work_mapping_state      (cms_mapping_id,state)
#  idx_db_cms_work_retry_predecessor  (retry_of_work_id) UNIQUE
#  idx_db_cms_work_uuid               (work_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_mapping_id => discussion_bridge_cms_mappings.id)
#  fk_rails_...  (retry_of_work_id => discussion_bridge_cms_work.id)
#
