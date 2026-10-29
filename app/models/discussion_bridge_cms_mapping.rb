# frozen_string_literal: true

class DiscussionBridgeCmsMapping < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_mappings"

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding"
  has_many :work_items, class_name: "DiscussionBridgeCmsWork", foreign_key: :cms_mapping_id

  validates :mapping_id, :source_id, :mapping_revision, presence: true
  validates :mapping_id, uniqueness: true
  validates :mapping_state, inclusion: { in: %w[pending active attention withdrawn] }
  validates :fence_generation, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                             less_than_or_equal_to: 9_007_199_254_740_991 }
  validate :binding_is_same_owned_source

  private

  def binding_is_same_owned_source
    binding = content_binding
    return if binding && binding.content_connection_id == content_connection_id &&
      binding.role == "presentation" && binding.bridge_record.direction == "from_discourse" &&
      source_id == "topic:#{binding.bridge_record.topic_id}"

    errors.add(:content_binding, "must identify the same connection-owned native source")
  end
end

# == Schema Information
#
# Table name: discussion_bridge_cms_mappings
#
#  id                                :bigint           not null, primary key
#  desired_source_revision           :string(128)
#  destination_native_revision       :string(128)
#  fence_generation                  :bigint           default(0), not null
#  mapping_revision                  :string(128)      not null
#  mapping_state                     :string(16)       default("pending"), not null
#  native_result                     :jsonb
#  prepared_transaction              :jsonb
#  presentation_move_intent          :jsonb
#  publicly_verified_at              :datetime
#  publicly_verified_source_revision :string(128)
#  source_created_at                 :datetime
#  source_updated_at                 :datetime
#  synchronized_at                   :datetime
#  synchronized_source_revision      :string(128)
#  verified_result                   :jsonb
#  created_at                        :datetime         not null
#  updated_at                        :datetime         not null
#  content_binding_id                :bigint           not null
#  content_connection_id             :bigint           not null
#  destination_native_id             :string(255)
#  mapping_id                        :uuid             not null
#  source_id                         :string(255)      not null
#
# Indexes
#
#  idx_db_cms_mapping_binding          (content_binding_id) UNIQUE
#  idx_db_cms_mapping_native_identity  (content_connection_id,destination_native_id) UNIQUE WHERE (destination_native_id IS NOT NULL)
#  idx_db_cms_mapping_source           (content_connection_id,source_id) UNIQUE
#  idx_db_cms_mapping_uuid             (mapping_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (content_binding_id => discussion_bridge_content_bindings.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
