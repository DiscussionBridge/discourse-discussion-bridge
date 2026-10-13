# frozen_string_literal: true

class DiscussionBridgeCmsSourceIntent < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_intents"
  belongs_to :cms_source_stream, class_name: "DiscussionBridgeCmsSourceStream"
  belongs_to :publication_event, class_name: "DiscussionBridgeCmsSourceEvent", optional: true
  has_many :source_revisions,
           class_name: "DiscussionBridgeCmsSourceRevision",
           foreign_key: :cms_source_intent_id
  validates :state, inclusion: { in: %w[active revoked attention] }
end
