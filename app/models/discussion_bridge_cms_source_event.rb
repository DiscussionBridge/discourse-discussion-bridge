# frozen_string_literal: true

class DiscussionBridgeCmsSourceEvent < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_events"
  belongs_to :cms_source_stream, class_name: "DiscussionBridgeCmsSourceStream"
  belongs_to :cms_source_intent, class_name: "DiscussionBridgeCmsSourceIntent"
  before_update { throw(:abort) }
  before_destroy { throw(:abort) }
end
