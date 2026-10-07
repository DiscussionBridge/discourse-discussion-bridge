# frozen_string_literal: true

class DiscussionBridgeDestinationPolicy < ActiveRecord::Base
  self.table_name = "discussion_bridge_destination_policies"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :catalog_revision, class_name: "DiscussionBridgeCatalogRevision"
  belongs_to :approved_by, class_name: "User"

  def readonly?
    persisted?
  end

  def self.current(connection)
    where(content_connection_id: connection.id).where(
      "id IN (SELECT MAX(id) FROM discussion_bridge_destination_policies WHERE content_connection_id = ? GROUP BY destination_policy_id)",
      connection.id,
    ).order(:destination_policy_id)
  end
end

# == Schema Information
#
# Table name: discussion_bridge_destination_policies
#
#  id                    :bigint           not null, primary key
#  definition            :jsonb            not null
#  platform_profile      :string(32)       not null
#  policy_revision       :string(255)      not null
#  created_at            :datetime         not null
#  approved_by_id        :bigint           not null
#  catalog_revision_id   :bigint           not null
#  content_connection_id :bigint           not null
#  destination_policy_id :string(255)      not null
#
# Indexes
#
#  idx_db_destination_policy_current   (content_connection_id,destination_policy_id,id)
#  idx_db_destination_policy_revision  (policy_revision) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (approved_by_id => users.id)
#  fk_rails_...  (catalog_revision_id => discussion_bridge_catalog_revisions.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
