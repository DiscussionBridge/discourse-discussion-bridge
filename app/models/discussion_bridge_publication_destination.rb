# frozen_string_literal: true

class DiscussionBridgePublicationDestination < ActiveRecord::Base
  self.table_name = "discussion_bridge_publication_destinations"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding"
  belongs_to :desired_work, class_name: "DiscussionBridgePublicationWork", optional: true
  belongs_to :active_work, class_name: "DiscussionBridgePublicationWork", optional: true
end

# == Schema Information
#
# Table name: discussion_bridge_publication_destinations
#
#  id                    :bigint           not null, primary key
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  active_work_id        :bigint
#  bridge_record_id      :bigint           not null
#  content_binding_id    :bigint           not null
#  content_connection_id :bigint           not null
#  desired_work_id       :bigint
#  destination_policy_id :string(255)      not null
#  resource_id           :string(36)       not null
#
# Indexes
#
#  idx_db_destination_identity  (content_connection_id,destination_policy_id,resource_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (active_work_id => discussion_bridge_publication_works.id)
#  fk_rails_...  (bridge_record_id => discussion_bridge_bridge_records.id)
#  fk_rails_...  (content_binding_id => discussion_bridge_content_bindings.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#  fk_rails_...  (desired_work_id => discussion_bridge_publication_works.id)
#
