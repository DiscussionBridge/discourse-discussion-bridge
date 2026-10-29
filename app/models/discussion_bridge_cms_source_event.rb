# frozen_string_literal: true

class DiscussionBridgeCmsSourceEvent < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_events"
  belongs_to :cms_source_stream, class_name: "DiscussionBridgeCmsSourceStream"
  belongs_to :cms_source_intent, class_name: "DiscussionBridgeCmsSourceIntent"
  before_update { throw(:abort) }
  before_destroy { throw(:abort) }
end

# == Schema Information
#
# Table name: discussion_bridge_cms_source_events
#
#  id                   :bigint           not null, primary key
#  event_sequence       :bigint           not null
#  payload              :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  cms_source_intent_id :bigint           not null
#  cms_source_stream_id :bigint           not null
#  event_id             :uuid             not null
#
# Indexes
#
#  idx_db_cms_event_stream_sequence  (cms_source_stream_id,event_sequence) UNIQUE
#  idx_db_cms_event_uuid             (event_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_source_intent_id => discussion_bridge_cms_source_intents.id)
#  fk_rails_...  (cms_source_stream_id => discussion_bridge_cms_source_streams.id)
#
