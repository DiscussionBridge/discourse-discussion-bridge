# frozen_string_literal: true

class DiscussionBridgePresentationUrlHistory < ActiveRecord::Base
  self.table_name = "discussion_bridge_presentation_url_histories"

  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding"
  belongs_to :verified_by, class_name: "User"

  validates :old_canonical_url, :new_canonical_url, :old_canonical_url_digest, presence: true
  validates :old_canonical_url_digest, length: { is: 64 }, uniqueness: true
  validates :redirect_status, inclusion: { in: [301, 308] }
  validate :different_urls

  private

  def different_urls
    errors.add(:new_canonical_url, "must differ from old URL") if
      old_canonical_url == new_canonical_url
  end
end
