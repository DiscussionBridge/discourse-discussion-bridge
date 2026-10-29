# frozen_string_literal: true

class DiscussionBridgeCmsAttentionInspection < ActiveRecord::Base
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping"
  belongs_to :cms_work, class_name: "DiscussionBridgeCmsWork"
  validates :inspection_id, :context_sha256, :payload_tree, presence: true
  validates :status, inclusion: { in: %w[waiting ready not_ready stale unsupported] }
end

# == Schema Information
#
# Table name: discussion_bridge_cms_attention_inspections
#
#  id                    :bigint           not null, primary key
#  context_sha256        :string(64)       not null
#  issue                 :string(64)       default("none"), not null
#  observation_tree      :jsonb
#  observed_at           :datetime
#  payload_tree          :jsonb            not null
#  status                :string(32)       default("waiting"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  actor_user_id         :bigint           not null
#  cms_mapping_id        :bigint           not null
#  cms_work_id           :bigint           not null
#  content_connection_id :bigint           not null
#  inspection_id         :uuid             not null
#
# Indexes
#
#  idx_db_attention_inspection_feed  (content_connection_id,id)
#  idx_db_attention_inspection_uuid  (inspection_id) UNIQUE
#  idx_db_attention_inspection_work  (cms_work_id,id)
#
# Foreign Keys
#
#  fk_rails_...  (cms_mapping_id => discussion_bridge_cms_mappings.id)
#  fk_rails_...  (cms_work_id => discussion_bridge_cms_work.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
