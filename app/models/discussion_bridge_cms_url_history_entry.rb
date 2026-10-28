# frozen_string_literal: true

class DiscussionBridgeCmsUrlHistoryEntry < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_url_history_entries"
  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping", optional: true
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding", optional: true
  validate do
    errors.add(:base, "must identify one URL owner") unless cms_mapping_id.nil? != content_binding_id.nil?
  end
  validates :url, :retired_at, :move_id, presence: true
end
