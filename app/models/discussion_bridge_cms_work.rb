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
