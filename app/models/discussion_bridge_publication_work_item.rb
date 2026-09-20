# frozen_string_literal: true

class DiscussionBridgePublicationWorkItem < ActiveRecord::Base
  self.table_name = "discussion_bridge_publication_work_items"

  ACTIONS = %w[publish unpublish].freeze
  STATES = %w[queued claimed retrying current held unpublished attention failed].freeze
  ATTENTION_STATES = %w[attention failed].freeze
  ACTIVE_STATES = %w[queued claimed retrying].freeze

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord", optional: true

  validates :content_connection, :topic_id, :action, :state, presence: true
  validates :topic_id, numericality: { only_integer: true, greater_than: 0 }
  validates :topic_id, uniqueness: { scope: :content_connection_id }
  validates :action, inclusion: { in: ACTIONS }
  validates :state, inclusion: { in: STATES }
  validates :reason, :last_error_code, length: { maximum: 64 }, allow_nil: true
  validates :source_revision, length: { maximum: 128 }, allow_nil: true
  validates :publication_revision, :policy_revision, :lease_token,
            length: { maximum: 64 }, allow_nil: true
  validates :last_error_detail, length: { maximum: 1000 }, allow_nil: true
end
