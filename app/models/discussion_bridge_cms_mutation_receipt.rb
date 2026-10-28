# frozen_string_literal: true

class DiscussionBridgeCmsMutationReceipt < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_mutation_receipts"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
end
