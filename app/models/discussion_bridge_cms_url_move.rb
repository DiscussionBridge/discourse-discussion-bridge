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
