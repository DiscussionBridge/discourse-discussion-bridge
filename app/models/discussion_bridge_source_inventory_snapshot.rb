# frozen_string_literal: true

class DiscussionBridgeSourceInventorySnapshot < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_inventory_snapshots"

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  attr_readonly :content_connection_id, :public_id, :policy_revision, :observation_cut, :established_at
  validates :public_id, format: { with: /\Adbs_[a-f0-9]{32}\z/ }, uniqueness: true
  validates :policy_revision, :established_at, :last_read_at, presence: true
  validates :observation_cut, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end

# == Schema Information
#
# Table name: discussion_bridge_source_inventory_snapshots
#
#  id                    :bigint           not null, primary key
#  established_at        :datetime         not null
#  last_read_at          :datetime         not null
#  observation_cut       :bigint           not null
#  policy_revision       :string(255)      not null
#  content_connection_id :bigint           not null
#  public_id             :string(36)       not null
#
# Indexes
#
#  idx_db_inventory_snapshot_public  (public_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
