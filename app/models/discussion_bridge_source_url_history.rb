# frozen_string_literal: true

class DiscussionBridgeSourceUrlHistory < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_url_histories"

  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding"
  belongs_to :verified_by, class_name: "User"

  validates :old_canonical_url, :new_canonical_url,
            :old_canonical_url_digest, :verified_at, presence: true
  validates :old_canonical_url_digest, length: { is: 64 }
  validates :redirect_status, inclusion: { in: [301, 308] }
  validate :urls_are_distinct

  private

  def urls_are_distinct
    errors.add(:new_canonical_url, "must differ from the retired URL") if
      old_canonical_url == new_canonical_url
  end
end
