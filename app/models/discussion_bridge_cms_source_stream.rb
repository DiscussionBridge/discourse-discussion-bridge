# frozen_string_literal: true

class DiscussionBridgeCmsSourceStream < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_streams"
  belongs_to :content_connection,
             class_name: "DiscussionBridgeContentConnection"
  has_many :source_intents,
           class_name: "DiscussionBridgeCmsSourceIntent",
           foreign_key: :cms_source_stream_id
  has_many :source_events,
           class_name: "DiscussionBridgeCmsSourceEvent",
           foreign_key: :cms_source_stream_id
  has_many :source_cursors,
           class_name: "DiscussionBridgeCmsSourceCursor",
           foreign_key: :cms_source_stream_id
  validates :scan_state, inclusion: { in: %w[uninitialized scanning complete] }
  validates :scan_phase, inclusion: { in: %w[topics retirement] }
  validates :lifecycle_error_code, length: { maximum: 64 }, allow_nil: true
  validates :source_scope_revision,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: DiscussionBridge::CmsProtocol::MAX_COUNTER
            }

  def assert_mutation_capacity!
    if source_scope_revision >= DiscussionBridge::CmsProtocol::MAX_COUNTER ||
         event_sequence >= DiscussionBridge::CmsSourceStore::MAX_SEQUENCE ||
         lifecycle_error_code == "storage_exhausted"
      DiscussionBridge::CmsProtocol.reject!("storage_exhausted")
    end
    true
  end
end

# == Schema Information
#
# Table name: discussion_bridge_cms_source_streams
#
#  id                    :bigint           not null, primary key
#  event_sequence        :bigint           default(0), not null
#  lifecycle_error_code  :string(64)
#  lifecycle_failed_at   :datetime
#  publication_lane      :string(120)      not null
#  scan_completed_at     :datetime
#  scan_phase            :string(16)       default("topics"), not null
#  scan_scope_signature  :string(64)
#  scan_state            :string(16)       default("uninitialized"), not null
#  source_scope_revision :bigint           default(0), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  content_connection_id :bigint           not null
#  scan_high_intent_id   :bigint
#  scan_high_topic_id    :bigint
#  scan_last_intent_id   :bigint           default(0), not null
#  scan_last_topic_id    :bigint           default(0), not null
#
# Indexes
#
#  idx_db_cms_stream_connection_lane  (content_connection_id,publication_lane) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
