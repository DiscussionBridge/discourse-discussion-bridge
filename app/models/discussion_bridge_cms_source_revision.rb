# frozen_string_literal: true

class DiscussionBridgeCmsSourceRevision < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_revisions"
  belongs_to :cms_source_intent, class_name: "DiscussionBridgeCmsSourceIntent"
  before_update { throw(:abort) }
  before_destroy { throw(:abort) }
end
