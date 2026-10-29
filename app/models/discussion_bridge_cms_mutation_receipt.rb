# frozen_string_literal: true

class DiscussionBridgeCmsMutationReceipt < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_mutation_receipts"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
end

# == Schema Information
#
# Table name: discussion_bridge_cms_mutation_receipts
#
#  id                    :bigint           not null, primary key
#  path_resource         :string(36)       default(""), not null
#  request_tree          :jsonb            not null
#  response_body         :jsonb
#  response_status       :integer          not null
#  route                 :string(64)       not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  content_connection_id :bigint           not null
#  mutation_id           :uuid             not null
#  native_actor_user_id  :bigint
#
# Indexes
#
#  idx_db_cms_mutation_identity  (content_connection_id,route,path_resource,mutation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
