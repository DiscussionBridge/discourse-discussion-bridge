# frozen_string_literal: true

class DiscussionBridgeSourceRevocation < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_revocations"

  REASONS = %w[source_unpublished source_deleted scope_removed policy_removed operator_hold].freeze
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding"
  belongs_to :native_source_revision, class_name: "DiscussionBridgeNativeSourceRevision"
  validates :public_id, format: { with: /\Adbr_[a-f0-9]{32}\z/ }, uniqueness: true
  validates :binding_public_id, format: { with: /\Adbb_[a-f0-9]{32}\z/ }
  validates :reason, inclusion: { in: REASONS }
  validates :source_revision, :effective_at_raw, presence: true
  validates :source_revision, length: { maximum: 255 }
  validates :source_revision_sequence, numericality: {
    only_integer: true, greater_than: 0, less_than_or_equal_to: 9_007_199_254_740_991,
  }
  validates :identity_digest, :context_digest, format: { with: /\A[a-f0-9]{64}\z/ }
  validates :identity_digest, uniqueness: true
  validates :restorable, inclusion: { in: [true, false] }

  def readonly?
    persisted?
  end
end

# == Schema Information
#
# Table name: discussion_bridge_source_revocations
#
#  id                        :bigint           not null, primary key
#  context_digest            :string(64)       not null
#  effective_at_raw          :text             not null
#  identity_digest           :string(64)       not null
#  reason                    :string(32)       not null
#  restorable                :boolean          not null
#  source_revision           :string(255)      not null
#  source_revision_sequence  :bigint           not null
#  binding_public_id         :string(36)       not null
#  bridge_record_id          :bigint           not null
#  content_binding_id        :bigint           not null
#  content_connection_id     :bigint           not null
#  native_source_revision_id :bigint           not null
#  public_id                 :string(36)       not null
#  resource_id               :string(36)       not null
#
# Indexes
#
#  idx_db_revocation_connection_cut  (content_connection_id,id)
#  idx_db_revocation_identity        (identity_digest) UNIQUE
#  idx_db_revocation_public          (public_id) UNIQUE
#  idx_db_revocation_resource        (content_connection_id,resource_id,id)
#
# Foreign Keys
#
#  fk_rails_...  (bridge_record_id => discussion_bridge_bridge_records.id)
#  fk_rails_...  (content_binding_id => discussion_bridge_content_bindings.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#  fk_rails_...  (native_source_revision_id => discussion_bridge_native_source_revisions.id)
#
