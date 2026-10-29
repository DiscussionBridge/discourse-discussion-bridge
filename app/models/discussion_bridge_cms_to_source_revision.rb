# frozen_string_literal: true

class DiscussionBridgeCmsToSourceRevision < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_to_source_revisions"
  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  validates :source_revision, :identity_sha256, :accepted_at, presence: true
  validates :source_revision, length: { maximum: 128 }
  validates :identity_sha256, format: { with: /\A[0-9a-f]{64}\z/ }

  def readonly?
    persisted? || super
  end
end

# == Schema Information
#
# Table name: discussion_bridge_cms_to_source_revisions
#
#  id               :bigint           not null, primary key
#  accepted_at      :datetime         not null
#  identity_sha256  :string(64)       not null
#  source_revision  :string(128)      not null
#  bridge_record_id :bigint           not null
#
# Indexes
#
#  idx_db_cms_to_source_revision  (bridge_record_id,source_revision) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (bridge_record_id => discussion_bridge_bridge_records.id)
#

