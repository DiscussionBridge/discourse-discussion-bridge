# frozen_string_literal: true

class DiscussionBridgeCmsUrlHistoryEntry < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_url_history_entries"
  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping"
  validates :url, :retired_at, :move_id, presence: true
end
