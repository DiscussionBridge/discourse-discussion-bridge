# frozen_string_literal: true

class DiscussionBridgeBridgeRecord < ActiveRecord::Base
  self.table_name = "discussion_bridge_bridge_records"

  DIRECTIONS = %w[to_discourse from_discourse].freeze
  STATES = %w[reserved healthy migration attention failed].freeze
  DESTINATION_STATES = %w[pending healthy held attention failed].freeze
  DELIVERY_OUTCOMES = %w[created updated unchanged held unpublished failed].freeze
  PUBLICATION_PROGRAMS = %w[legacy forum_sync_pending forum_sync].freeze

  belongs_to :topic, optional: true
  belongs_to :effective_actor, class_name: "User", optional: true
  belongs_to :retry_authorized_by, class_name: "User", optional: true
  has_many :content_bindings,
           class_name: "DiscussionBridgeContentBinding",
           foreign_key: :bridge_record_id,
           dependent: :restrict_with_error
  has_many :content_connections, through: :content_bindings
  has_many :publication_work_items,
           class_name: "DiscussionBridgePublicationWorkItem",
           foreign_key: :bridge_record_id,
           dependent: :nullify

  validates :resource_id, :direction, :state, :title, presence: true
  validates :resource_id, length: { is: 36 }, uniqueness: true
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :state, inclusion: { in: STATES }
  validates :title, length: { maximum: DiscussionBridge::ConnectionRequest::MAX_TITLE_BYTES }
  validates :primary_source_author_id, length: { maximum: 255 }, allow_nil: true
  validates :reservation_token, length: { is: 64 }, allow_nil: true
  validates :destination_state, inclusion: { in: DESTINATION_STATES }, allow_nil: true
  validates :last_delivery_outcome, inclusion: { in: DELIVERY_OUTCOMES }, allow_nil: true
  validates :publication_program, inclusion: { in: PUBLICATION_PROGRAMS }
  validates :acknowledged_source_revision, length: { maximum: 128 }, allow_nil: true
  validates :acknowledged_publication_revision, length: { is: 64 }, allow_nil: true
  validates :acknowledged_mapping_revision, length: { is: 64 }, allow_nil: true
  validates :attempted_publication_revision, length: { is: 64 }, allow_nil: true
  validates :attempted_mapping_revision, length: { is: 64 }, allow_nil: true
  validates :pending_publication_revision, length: { is: 64 }, allow_nil: true
  validates :pending_mapping_revision, length: { is: 64 }, allow_nil: true
  validates :last_delivery_error_code, length: { maximum: 64 }, allow_nil: true
  validates :last_delivery_error_detail, length: { maximum: 1000 }, allow_nil: true

  def active_binding(role)
    content_bindings.find_by(role: role, state: "active")
  end
end

# == Schema Information
#
# Table name: discussion_bridge_bridge_records
#
#  id                                :bigint           not null, primary key
#  acknowledged_at                   :datetime
#  acknowledged_destination          :jsonb            not null
#  acknowledged_mapping_revision     :string(64)
#  acknowledged_publication_revision :string(64)
#  acknowledged_source_revision      :string(128)
#  attempted_destination             :jsonb            not null
#  attempted_mapping_revision        :string(64)
#  attempted_publication_revision    :string(64)
#  delivery_attempt_count            :integer          default(0), not null
#  destination_state                 :string(32)
#  direction                         :string(32)       not null
#  effective_visibility              :string(32)       default("unlisted"), not null
#  lane                              :string(64)
#  last_delivery_attempt_at          :datetime
#  last_delivery_error_code          :string(64)
#  last_delivery_error_detail        :string(1000)
#  last_delivery_outcome             :string(32)
#  pending_destination               :jsonb            not null
#  pending_mapping_revision          :string(64)
#  pending_publication_revision      :string(64)
#  publication_program               :string(32)       default("legacy"), not null
#  requested_visibility              :string(32)       default("unlisted"), not null
#  reservation_token                 :string(64)
#  retry_authorized_at               :datetime
#  source_authors                    :jsonb            not null
#  state                             :string(32)       default("reserved"), not null
#  title                             :string(1024)     not null
#  created_at                        :datetime         not null
#  updated_at                        :datetime         not null
#  effective_actor_id                :bigint
#  primary_source_author_id          :string(255)
#  resource_id                       :string(64)       not null
#  retry_authorized_by_id            :bigint
#  topic_id                          :bigint
#
# Indexes
#
#  idx_db_bridge_records_destination_state  (destination_state)
#  idx_db_bridge_records_reservation        (reservation_token) UNIQUE
#  idx_db_bridge_records_resource_id        (resource_id) UNIQUE
#  idx_db_bridge_records_state              (state)
#  idx_db_bridge_records_topic_id           (topic_id)
#
