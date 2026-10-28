# frozen_string_literal: true

class DiscussionBridgeCmsAttentionRecovery < ActiveRecord::Base
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping"
  belongs_to :inspection_record, class_name: "DiscussionBridgeCmsAttentionInspection"
  belongs_to :predecessor_work, class_name: "DiscussionBridgeCmsWork"
  belongs_to :successor_work, class_name: "DiscussionBridgeCmsWork"
  validates :recovery_id, :context_sha256, :payload_tree, :attention_snapshot, presence: true
  validates :mode, inclusion: { in: %w[retry settle_restored_baseline] }
  def readonly? = persisted?
end
