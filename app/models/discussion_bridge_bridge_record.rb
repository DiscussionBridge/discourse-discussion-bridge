# frozen_string_literal: true

class DiscussionBridgeBridgeRecord < ActiveRecord::Base
  self.table_name = "discussion_bridge_bridge_records"

  DIRECTIONS = %w[to_discourse from_discourse].freeze
  STATES = %w[reserved healthy migration attention failed].freeze

  belongs_to :topic, optional: true
  belongs_to :effective_actor, class_name: "User", optional: true
  belongs_to :retry_authorized_by, class_name: "User", optional: true
  has_many :content_bindings,
           class_name: "DiscussionBridgeContentBinding",
           foreign_key: :bridge_record_id,
           dependent: :restrict_with_error
  has_many :content_connections, through: :content_bindings

  validates :resource_id, :direction, :state, :title, presence: true
  validates :resource_id, length: { is: 36 }, uniqueness: true
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :state, inclusion: { in: STATES }
  validates :title, length: { maximum: DiscussionBridge::ConnectionRequest::MAX_TITLE_BYTES }
  validates :primary_source_author_id, length: { maximum: 255 }, allow_nil: true
  validates :reservation_token, length: { is: 64 }, allow_nil: true

  validates :source_revision, length: { maximum: 255 }, allow_nil: true
  validates :source_revision_sequence, numericality: {
    only_integer: true, greater_than: 0, less_than_or_equal_to: 9_007_199_254_740_991,
  }, allow_nil: true
  validates :source_content_bytes, numericality: {
    only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 9_007_199_254_740_991,
  }, allow_nil: true
  validates :source_content_sha256, :source_request_fingerprint,
            format: { with: /\A[a-f0-9]{64}\z/ }, allow_nil: true
  validates :content_disposition, inclusion: { in: %w[complete excerpt] }, allow_nil: true
  validates :source_context_state, inclusion: { in: %w[observed applied] }, allow_nil: true

  def known_source_context?
    fields = %w[source_revision source_revision_sequence source_created_at_raw source_updated_at_raw
       source_content_sha256 source_content_bytes content_disposition source_context_state
       source_request_fingerprint]
    return false unless fields.all? { |field| !self[field].nil? }
    return false unless source_revision.present? && source_revision.bytesize <= 255 &&
      source_revision_sequence.is_a?(Integer) && source_revision_sequence.between?(1, 9_007_199_254_740_991) &&
      source_content_bytes.is_a?(Integer) && source_content_bytes.between?(0, 9_007_199_254_740_991) &&
      /\A[a-f0-9]{64}\z/.match?(source_content_sha256) && /\A[a-f0-9]{64}\z/.match?(source_request_fingerprint) &&
      %w[complete excerpt].include?(content_disposition) && %w[observed applied].include?(source_context_state)
    DiscussionBridge::BridgeRecordRequest.timestamp!(source_updated_at_raw) >=
      DiscussionBridge::BridgeRecordRequest.timestamp!(source_created_at_raw)
  rescue DiscussionBridge::AdapterRequestBoundary::Error
    false
  end

  def active_binding(role)
    content_bindings.find_by(role: role, state: "active")
  end
end

# == Schema Information
#
# Table name: discussion_bridge_bridge_records
#
#  id                         :bigint           not null, primary key
#  content_disposition        :string(32)
#  direction                  :string(32)       not null
#  effective_visibility       :string(32)       default("unlisted"), not null
#  lane                       :string(64)
#  requested_visibility       :string(32)       default("unlisted"), not null
#  reservation_token          :string(64)
#  retry_authorized_at        :datetime
#  source_authors             :jsonb            not null
#  source_content_bytes       :bigint
#  source_content_sha256      :string(64)
#  source_context_state       :string(32)
#  source_created_at_raw      :text
#  source_request_fingerprint :string(64)
#  source_revision            :string(255)
#  source_revision_sequence   :bigint
#  source_updated_at_raw      :text
#  state                      :string(32)       default("reserved"), not null
#  title                      :string(1024)     not null
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  effective_actor_id         :bigint
#  primary_source_author_id   :string(255)
#  resource_id                :string(64)       not null
#  retry_authorized_by_id     :bigint
#  topic_id                   :bigint
#
# Indexes
#
#  idx_db_bridge_records_reservation  (reservation_token) UNIQUE
#  idx_db_bridge_records_resource_id  (resource_id) UNIQUE
#  idx_db_bridge_records_state        (state)
#  idx_db_bridge_records_topic_id     (topic_id)
#
