# frozen_string_literal: true

class DiscussionBridgeSourceInventoryEntry < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_inventory_entries"

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding"
  belongs_to :native_source_revision, class_name: "DiscussionBridgeNativeSourceRevision"
  validates :resource_id, :topic_id, :binding_public_id, :canonical_url, :observed_at, presence: true
  validates :context_digest, format: { with: /\A[a-f0-9]{64}\z/ }

  def readonly?
    persisted?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_source_inventory_entries
#
#  id                        :bigint           not null, primary key
#  canonical_url             :text             not null
#  context_digest            :string(64)       not null
#  lane                      :string(100)
#  observed_at               :datetime         not null
#  binding_public_id         :string(36)       not null
#  bridge_record_id          :bigint           not null
#  content_binding_id        :bigint           not null
#  content_connection_id     :bigint           not null
#  native_source_revision_id :bigint           not null
#  resource_id               :string(36)       not null
#  topic_id                  :bigint           not null
#
# Indexes
#
#  idx_db_inventory_connection_cut  (content_connection_id,id)
#  idx_db_inventory_record_cut      (content_connection_id,bridge_record_id,id)
#
# Foreign Keys
#
#  fk_rails_...  (bridge_record_id => discussion_bridge_bridge_records.id)
#  fk_rails_...  (content_binding_id => discussion_bridge_content_bindings.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#  fk_rails_...  (native_source_revision_id => discussion_bridge_native_source_revisions.id)
#
