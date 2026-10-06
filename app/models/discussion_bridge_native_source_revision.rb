# frozen_string_literal: true

class DiscussionBridgeNativeSourceRevision < ActiveRecord::Base
  self.table_name = "discussion_bridge_native_source_revisions"

  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  validates :sequence, numericality: {
    only_integer: true, greater_than: 0, less_than_or_equal_to: 9_007_199_254_740_991,
  }, uniqueness: { scope: :bridge_record_id }
  validates :revision, presence: true, length: { maximum: 255 }, uniqueness: { scope: :bridge_record_id }
  validates :fingerprint, format: { with: /\A[a-f0-9]{64}\z/ }
  validates :metadata, :captured_at, presence: true

  def readonly?
    persisted?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_native_source_revisions
#
#  id               :bigint           not null, primary key
#  captured_at      :datetime         not null
#  content_html     :text             not null
#  fingerprint      :string(64)       not null
#  metadata         :jsonb            not null
#  revision         :string(255)      not null
#  sequence         :bigint           not null
#  bridge_record_id :bigint           not null
#
# Indexes
#
#  idx_db_native_source_record_revision  (bridge_record_id,revision) UNIQUE
#  idx_db_native_source_record_sequence  (bridge_record_id,sequence) UNIQUE
#
