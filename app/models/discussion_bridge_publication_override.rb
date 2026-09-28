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

# == Schema Information
#
# Table name: discussion_bridge_publication_overrides
#
#  id                    :bigint           not null, primary key
#  decision              :string(16)       not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  content_connection_id :bigint           not null
#  set_by_id             :bigint           not null
#  topic_id              :bigint           not null
#
# Indexes
#
#  idx_db_publication_override_connection_topic  (content_connection_id,topic_id) UNIQUE
#  idx_db_publication_override_topic             (topic_id)
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#  fk_rails_...  (set_by_id => users.id)
#  fk_rails_...  (topic_id => topics.id)
#
