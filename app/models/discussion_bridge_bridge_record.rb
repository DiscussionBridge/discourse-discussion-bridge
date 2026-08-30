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
  validates :reservation_token, length: { is: 64 }, allow_nil: true

  def active_binding(role)
    content_bindings.find_by(role: role, state: "active")
  end
end
