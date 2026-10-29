# frozen_string_literal: true

class DiscussionBridgeCmsUrlMove < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_url_moves"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding"
  belongs_to :cms_mapping, class_name: "DiscussionBridgeCmsMapping", optional: true
  validates :move_id, :expected_revision, :old_url, :new_url, :proof_nonce, :prepared_at, presence: true
  validates :move_id, uniqueness: true
  validates :kind, inclusion: { in: %w[presentation source] }
  validates :state, inclusion: { in: %w[prepared committed aborted attention] }
  validate :same_owned_binding

  private

  def same_owned_binding
    binding = content_binding
    expected_role = kind == "source" ? "source" : "presentation"
    valid = binding && binding.content_connection_id == content_connection_id && binding.role == expected_role
    valid &&= kind == "source" ? cms_mapping.nil? : cms_mapping&.content_binding_id == binding.id
    errors.add(:content_binding, "must preserve the same owned native identity") unless valid
  end
end

# == Schema Information
#
# Table name: discussion_bridge_cms_url_moves
#
#  id                    :bigint           not null, primary key
#  authority             :jsonb
#  expected_revision     :string(128)      not null
#  kind                  :string(16)       not null
#  native_proof          :jsonb
#  new_url               :text             not null
#  old_ownership         :jsonb
#  old_url               :text             not null
#  prepared_at           :datetime         not null
#  proof_nonce           :string(43)       not null
#  state                 :string(16)       default("prepared"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  cms_mapping_id        :bigint
#  content_binding_id    :bigint           not null
#  content_connection_id :bigint           not null
#  move_id               :uuid             not null
#
# Indexes
#
#  idx_db_cms_url_move_binding  (content_binding_id,state)
#  idx_db_cms_url_move_uuid     (move_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_mapping_id => discussion_bridge_cms_mappings.id)
#  fk_rails_...  (content_binding_id => discussion_bridge_content_bindings.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
