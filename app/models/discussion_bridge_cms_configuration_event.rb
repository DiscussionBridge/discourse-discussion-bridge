# frozen_string_literal: true

class DiscussionBridgeCmsConfigurationEvent < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_configuration_events"
end

# == Schema Information
#
# Table name: discussion_bridge_cms_configuration_events
#
#  id                       :bigint           not null, primary key
#  configuration            :jsonb            not null
#  policy_revision          :string(128)      not null
#  previous_configuration   :jsonb
#  previous_policy_revision :string(128)
#  created_at               :datetime         not null
#  actor_user_id            :bigint           not null
#  content_connection_id    :bigint           not null
#
# Indexes
#
#  idx_db_cms_configuration_events  (content_connection_id,created_at,id)
#  idx_db_cms_policy_history_order  (content_connection_id,id)
#  idx_db_cms_policy_revision       (content_connection_id,policy_revision)
#
# Foreign Keys
#
#  fk_rails_...  (content_connection_id => discussion_bridge_content_connections.id)
#
