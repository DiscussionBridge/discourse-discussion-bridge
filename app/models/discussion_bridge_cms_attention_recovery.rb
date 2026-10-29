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

# == Schema Information
#
# Table name: discussion_bridge_cms_attention_recoveries
#
#  id                    :bigint           not null, primary key
#  attention_snapshot    :jsonb            not null
#  context_sha256        :string(64)       not null
#  mode                  :string(32)       not null
#  payload_tree          :jsonb            not null
#  created_at            :datetime         not null
#  actor_user_id         :bigint           not null
#  cms_mapping_id        :bigint           not null
#  content_connection_id :bigint           not null
#  inspection_record_id  :bigint           not null
#  predecessor_work_id   :bigint           not null
#  recovery_id           :uuid             not null
#  successor_work_id     :bigint           not null
#
# Indexes
#
#  idx_db_attention_recovery_feed         (content_connection_id,id)
#  idx_db_attention_recovery_predecessor  (predecessor_work_id) UNIQUE
#  idx_db_attention_recovery_successor    (successor_work_id) UNIQUE
#  idx_db_attention_recovery_uuid         (recovery_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_mapping_id => discussion_bridge_cms_mappings.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#  fk_rails_...  (inspection_record_id => discussion_bridge_cms_attention_inspections.id)
#  fk_rails_...  (predecessor_work_id => discussion_bridge_cms_work.id)
#  fk_rails_...  (successor_work_id => discussion_bridge_cms_work.id)
#
