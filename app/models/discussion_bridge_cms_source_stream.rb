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
