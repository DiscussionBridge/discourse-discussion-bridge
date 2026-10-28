# frozen_string_literal: true

class DiscussionBridgeCmsAttentionInspection < ActiveRecord::Base
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping"
  belongs_to :cms_work, class_name: "DiscussionBridgeCmsWork"
  validates :inspection_id, :context_sha256, :payload_tree, presence: true
  validates :status, inclusion: { in: %w[waiting ready not_ready stale unsupported] }
end
