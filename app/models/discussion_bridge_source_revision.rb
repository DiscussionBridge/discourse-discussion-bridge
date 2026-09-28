# frozen_string_literal: true

class DiscussionBridgeSourceRevision < ActiveRecord::Base
  self.table_name = "discussion_bridge_source_revisions"

  belongs_to :bridge_record, class_name: "DiscussionBridgeBridgeRecord"
  has_many :snapshot_items,
           class_name: "DiscussionBridgeSourceSnapshotItem",
           foreign_key: :source_revision_id,
           dependent: :restrict_with_error
  has_many :publication_works,
           class_name: "DiscussionBridgePublicationWork",
           foreign_key: :source_revision_id,
           dependent: :restrict_with_error

  validates :source_revision, :fingerprint, :topic_url, :title,
            :source_created_at, :source_updated_at, :presentation_mode,
            :content_html, :content_sha256, presence: true
  validates :source_revision, length: { maximum: 255 }, uniqueness: { scope: :bridge_record_id }
  validates :source_revision_sequence,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: :bridge_record_id }
  validates :fingerprint, length: { is: 64 }
  validates :title, length: { maximum: 1024 }
  validates :presentation_mode, inclusion: { in: DiscussionBridge::ConnectionCapability::PRESENTATION_MODES }
  validates :byte_length,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: DiscussionBridge::SourcePublicationProtocol::MAXIMUM_SOURCE_CONTENT_BYTES,
            }
  validates :content_sha256, format: { with: DiscussionBridge::SourcePublicationProtocol::SHA256_PATTERN }
  validate :collection_bounds

  private

  def collection_bounds
    errors.add(:source_authors, "contains too many items") if source_authors.length > 20
    errors.add(:categories, "contains too many items") if categories.length > 20
    errors.add(:tags, "contains too many items") if tags.length > 100
  end
end

# == Schema Information
#
# Table name: discussion_bridge_source_revisions
#
#  id                       :bigint           not null, primary key
#  byte_length              :bigint           not null
#  categories               :jsonb            not null
#  content_html             :text             not null
#  content_sha256           :string(64)       not null
#  fingerprint              :string(64)       not null
#  network_provenance       :jsonb
#  presentation_mode        :string(32)       not null
#  source_authors           :jsonb            not null
#  source_created_at        :datetime         not null
#  source_revision          :string(255)      not null
#  source_revision_sequence :bigint           not null
#  source_updated_at        :datetime         not null
#  tags                     :jsonb            not null
#  title                    :string(1024)     not null
#  topic_url                :text             not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  bridge_record_id         :bigint           not null
#
# Indexes
#
#  idx_db_source_revisions_record              (bridge_record_id)
#  idx_db_source_revisions_record_fingerprint  (bridge_record_id,fingerprint)
#  idx_db_source_revisions_record_revision     (bridge_record_id,source_revision) UNIQUE
#  idx_db_source_revisions_record_sequence     (bridge_record_id,source_revision_sequence) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (bridge_record_id => discussion_bridge_bridge_records.id)
#
