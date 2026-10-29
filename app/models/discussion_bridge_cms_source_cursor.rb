# frozen_string_literal: true

class DiscussionBridgeCmsSourceCursor < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_cursors"
  belongs_to :cms_source_stream, class_name: "DiscussionBridgeCmsSourceStream"
  belongs_to :snapshot_root, class_name: "DiscussionBridgeCmsSourceCursor", optional: true
  has_many :snapshot_items,
           class_name: "DiscussionBridgeCmsSourceSnapshotItem",
           foreign_key: :snapshot_root_id
  validates :kind, inclusion: { in: %w[initial changes checkpoint] }
end

# == Schema Information
#
# Table name: discussion_bridge_cms_source_cursors
#
#  id                   :bigint           not null, primary key
#  expires_at           :datetime         not null
#  high_water           :bigint           not null
#  invalidated_at       :datetime
#  kind                 :string(16)       not null
#  page_body            :jsonb
#  policy_revision      :string(128)      not null
#  position             :bigint           default(0), not null
#  scope_signature      :string(64)       not null
#  snapshot_count       :bigint           default(0), not null
#  token_digest         :string(64)       not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  cms_source_stream_id :bigint           not null
#  snapshot_root_id     :bigint
#
# Indexes
#
#  idx_db_cms_cursor_token  (token_digest) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_source_stream_id => discussion_bridge_cms_source_streams.id)
#  fk_rails_...  (snapshot_root_id => discussion_bridge_cms_source_cursors.id)
#
