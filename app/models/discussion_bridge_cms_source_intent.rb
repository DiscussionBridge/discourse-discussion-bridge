# frozen_string_literal: true

class DiscussionBridgeCmsSourceIntent < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_intents"
  belongs_to :cms_source_stream, class_name: "DiscussionBridgeCmsSourceStream"
  belongs_to :publication_event, class_name: "DiscussionBridgeCmsSourceEvent", optional: true
  has_many :source_revisions,
           class_name: "DiscussionBridgeCmsSourceRevision",
           foreign_key: :cms_source_intent_id
  validates :state, inclusion: { in: %w[active revoked attention] }
end

# == Schema Information
#
# Table name: discussion_bridge_cms_source_intents
#
#  id                      :bigint           not null, primary key
#  attention_code          :string(64)
#  current_source_revision :string(128)
#  state                   :string(16)       not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  cms_source_stream_id    :bigint           not null
#  publication_event_id    :bigint
#  source_id               :string(255)      not null
#  topic_id                :bigint           not null
#
# Indexes
#
#  idx_db_cms_intent_stream_source  (cms_source_stream_id,source_id) UNIQUE
#  idx_db_cms_intent_stream_state   (cms_source_stream_id,state)
#
# Foreign Keys
#
#  fk_rails_...  (cms_source_stream_id => discussion_bridge_cms_source_streams.id)
#  fk_rails_...  (publication_event_id => discussion_bridge_cms_source_events.id)
#
