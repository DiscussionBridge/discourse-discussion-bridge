# frozen_string_literal: true

class DiscussionBridgeSourceUrlHistory < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_url_histories"

  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding"
  belongs_to :verified_by, class_name: "User"

  validates :old_canonical_url, :new_canonical_url, :old_canonical_url_digest, presence: true
  validates :old_canonical_url_digest, length: { is: 64 }
  validates :redirect_status, inclusion: { in: [301, 308] }
  validate :different_urls

  private

  def different_urls
    errors.add(:new_canonical_url, "must differ from old URL") if
      old_canonical_url == new_canonical_url
  end
end

# == Schema Information
#
# Table name: discussion_bridge_source_url_histories
#
#  id                       :bigint           not null, primary key
#  new_canonical_url        :text             not null
#  old_canonical_url        :text             not null
#  old_canonical_url_digest :string(64)       not null
#  redirect_status          :integer          not null
#  verified_at              :datetime         not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  bridge_record_id         :bigint           not null
#  content_binding_id       :bigint           not null
#  verified_by_id           :bigint           not null
#
# Indexes
#
#  idx_db_source_old_url              (old_canonical_url_digest)
#  idx_db_source_url_history_binding  (content_binding_id)
#  idx_db_source_url_history_record   (bridge_record_id)
#
