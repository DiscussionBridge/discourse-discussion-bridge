# frozen_string_literal: true

class DiscussionBridgePublicationWork < ActiveRecord::Base
  self.table_name = "discussion_bridge_publication_works"

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  belongs_to :content_binding, class_name: "DiscussionBridgeContentBinding"
  belongs_to :source_revision_record,
             class_name: "DiscussionBridgeSourceRevision",
             foreign_key: :source_revision_id,
             optional: true
  belongs_to :source_revocation_record,
             class_name: "DiscussionBridgeSourceRevocation",
             foreign_key: :source_revocation_id,
             optional: true
  belongs_to :manual_retry_authorized_by, class_name: "User", optional: true
  has_many :acknowledgements,
           class_name: "DiscussionBridgePublicationAcknowledgement",
           foreign_key: :publication_work_id,
           dependent: :restrict_with_error

  validates :work_id, presence: true, uniqueness: true,
                      format: { with: ::DiscussionBridge::PublicationWorkProtocol::WORK_ID_PATTERN }
  validates :action, inclusion: { in: ::DiscussionBridge::PublicationWorkProtocol::ACTIONS }
  validates :state, inclusion: { in: ::DiscussionBridge::PublicationWorkProtocol::STATES }
  validates :source_revision, :policy_revision, :destination_policy_id,
            :catalog_revision, presence: true, length: { maximum: 255 }
  validates :source_revision_sequence, numericality: { only_integer: true, greater_than: 0 }
  validates :presentation_mode, inclusion: { in: ::DiscussionBridge::ConnectionCapability::PRESENTATION_MODES }
  validates :attempt_count,
            numericality: {
              only_integer: true,
              greater_than: 0,
              less_than_or_equal_to: ::DiscussionBridge::PublicationWorkProtocol::MAXIMUM_TOTAL_ATTEMPTS,
            }
  validates :retry_generation, :total_lease_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :worker_id, length: { maximum: ::DiscussionBridge::PublicationWorkProtocol::WORKER_ID_MAXIMUM_BYTES },
                        allow_nil: true
  validates :lease_token_digest, :stage_token_digest, length: { is: 64 }, allow_nil: true
  validates :failure_code,
            inclusion: { in: ::DiscussionBridge::PublicationWorkProtocol::FAILURE_CODES },
            allow_nil: true
  validate :resolved_state_is_bounded

  before_validation :assign_work_id, on: :create

  private

  def assign_work_id
    self.work_id ||= "dbw_#{SecureRandom.hex(16)}"
  end

  def resolved_state_is_bounded
    ::DiscussionBridge::PublicationWorkProtocol.validate_resolved_state!(self)
  rescue ::DiscussionBridge::AdapterRequestBoundary::Error
    errors.add(:base, "resolved publication state does not match the Adapter Protocol")
  end
end

# == Schema Information
#
# Table name: discussion_bridge_publication_works
#
#  id                            :bigint           not null, primary key
#  acknowledged_at               :datetime
#  action                        :string(32)       not null
#  attempt_count                 :integer          default(1), not null
#  available_at                  :datetime
#  catalog_revision              :string(255)      not null
#  deployed_at                   :datetime
#  failed_at                     :datetime
#  failure_code                  :string(64)
#  failure_detail                :text
#  failure_request_digest        :string(64)
#  failure_response_payload      :jsonb
#  last_acknowledged_stage       :string(32)
#  lease_expires_at              :datetime
#  lease_token_digest            :string(64)
#  leased_at                     :datetime
#  manual_retry_authorized_at    :datetime
#  native_limit_policy           :jsonb            not null
#  next_retry_at                 :datetime
#  policy_revision               :string(255)      not null
#  presentation_mode             :string(32)       not null
#  publicly_verified_at          :datetime
#  resolution_error              :string(64)
#  resolved_author               :jsonb            not null
#  resolved_container            :jsonb            not null
#  resolved_taxonomy             :jsonb            not null
#  retry_generation              :integer          default(0), not null
#  source_revision               :string(255)      not null
#  source_revision_sequence      :bigint           not null
#  stage_token_digest            :string(64)
#  state                         :string(32)       default("available"), not null
#  superseded_at                 :datetime
#  synchronized_at               :datetime
#  total_lease_seconds           :integer          default(0), not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#  bridge_record_id              :bigint           not null
#  content_binding_id            :bigint           not null
#  content_connection_id         :bigint           not null
#  destination_policy_id         :string(255)      not null
#  manual_retry_authorized_by_id :bigint
#  source_revision_id            :bigint
#  source_revocation_id          :bigint
#  work_id                       :string(36)       not null
#  worker_id                     :string(200)
#
# Indexes
#
#  idx_db_publication_works_binding     (content_binding_id)
#  idx_db_publication_works_claim       (content_connection_id,state,available_at)
#  idx_db_publication_works_connection  (content_connection_id)
#  idx_db_publication_works_identity    (content_connection_id,content_binding_id,source_revision,policy_revision,destination_policy_id,action) UNIQUE
#  idx_db_publication_works_public_id   (work_id) UNIQUE
#  idx_db_publication_works_record      (bridge_record_id)
#  idx_db_publication_works_revision    (source_revision_id)
#  idx_db_publication_works_revocation  (source_revocation_id)
#  idx_db_publication_works_serial      (content_binding_id,state)
#
# Foreign Keys
#
#  fk_rails_...  (bridge_record_id => discussion_bridge_bridge_records.id)
#  fk_rails_...  (content_binding_id => discussion_bridge_content_bindings.id)
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#  fk_rails_...  (manual_retry_authorized_by_id => users.id)
#  fk_rails_...  (source_revision_id => discussion_bridge_source_revisions.id)
#  fk_rails_...  (source_revocation_id => discussion_bridge_source_revocations.id)
#
