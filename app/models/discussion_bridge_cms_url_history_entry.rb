# frozen_string_literal: true

class DiscussionBridgeCmsUrlHistoryEntry < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_url_history_entries"
  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping", optional: true
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding", optional: true
  validate do
    errors.add(:base, "must identify one URL owner") if cms_mapping_id.nil? == content_binding_id.nil?
  end
  validates :url, :retired_at, :move_id, presence: true
end

# == Schema Information
#
# Table name: discussion_bridge_cms_url_history_entries
#
#  id                 :bigint           not null, primary key
#  retired_at         :datetime         not null
#  url                :text             not null
#  created_at         :datetime         not null
#  cms_mapping_id     :bigint
#  content_binding_id :bigint
#  move_id            :uuid             not null
#
# Indexes
#
#  idx_db_cms_history_mapping_move   (cms_mapping_id,move_id) UNIQUE
#  idx_db_cms_history_mapping_order  (cms_mapping_id,id)
#  idx_db_cms_source_history_move    (content_binding_id,move_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_mapping_id => discussion_bridge_cms_mappings.id)
#  fk_rails_...  (content_binding_id => discussion_bridge_content_bindings.id)
#
