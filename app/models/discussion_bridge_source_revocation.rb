# frozen_string_literal: true

class DiscussionBridgeSourceRevocation < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_revocations"

  REASONS = DiscussionBridge::SourcePublicationProtocol::REVOCATION_REASONS

  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  has_many :publication_works,
           class_name: "DiscussionBridgePublicationWork",
           foreign_key: :source_revocation_id,
           dependent: :restrict_with_error

  validates :revocation_id, :source_revision, :reason, :effective_at,
            :policy_revision, presence: true
  validates :revocation_id,
            format: { with: DiscussionBridge::SourcePublicationProtocol::REVOCATION_ID_PATTERN },
            uniqueness: true
  validates :source_revision, length: { maximum: 255 }
  validates :source_revision_sequence,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: :bridge_record_id }
  validates :reason, inclusion: { in: REASONS }
  validates :policy_revision, length: { maximum: 255 }
end

# == Schema Information
#
# Table name: discussion_bridge_source_revocations
#
#  id                       :bigint           not null, primary key
#  affected_binding_ids     :jsonb            not null
#  effective_at             :datetime         not null
#  policy_revision          :string(255)      not null
#  reason                   :string(32)       not null
#  restorable               :boolean          default(TRUE), not null
#  restored_at              :datetime
#  source_revision          :string(255)      not null
#  source_revision_sequence :bigint           not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  bridge_record_id         :bigint           not null
#  content_connection_id    :bigint           not null
#  revocation_id            :string(36)       not null
#
# Indexes
#
#  idx_db_source_revocations_connection       (content_connection_id)
#  idx_db_source_revocations_public_id        (revocation_id) UNIQUE
#  idx_db_source_revocations_record           (bridge_record_id)
#  idx_db_source_revocations_record_sequence  (bridge_record_id,source_revision_sequence) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (bridge_record_id => discussion_bridge_bridge_records.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
