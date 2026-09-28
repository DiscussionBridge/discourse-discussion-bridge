# frozen_string_literal: true

class DiscussionBridgePublicationOverride < ActiveRecord::Base
  self.table_name = "discussion_bridge_publication_overrides"

  DECISIONS = %w[include exclude].freeze

  belongs_to :content_connection, class_name: "DiscussionBridgeContentConnection"
  belongs_to :topic
  belongs_to :set_by, class_name: "User"

  validates :decision, inclusion: { in: DECISIONS }
  validates :topic_id, uniqueness: { scope: :content_connection_id }
end
