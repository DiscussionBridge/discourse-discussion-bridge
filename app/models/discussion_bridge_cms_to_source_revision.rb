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

