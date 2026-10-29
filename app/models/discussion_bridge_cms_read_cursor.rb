# frozen_string_literal: true

class DiscussionBridgeCmsReadCursor < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_read_cursors"
  belongs_to :cms_read_snapshot, class_name: "DiscussionBridgeCmsReadSnapshot"
end

# == Schema Information
#
# Table name: discussion_bridge_cms_read_cursors
#
#  id                   :bigint           not null, primary key
#  page_body            :jsonb
#  position             :bigint           not null
#  token_digest         :string(64)       not null
#  created_at           :datetime         not null
#  cms_read_snapshot_id :bigint           not null
#
# Indexes
#
#  idx_db_cms_read_cursor_token  (token_digest) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_read_snapshot_id => discussion_bridge_cms_read_snapshots.id)
#
