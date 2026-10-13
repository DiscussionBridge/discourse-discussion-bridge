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
