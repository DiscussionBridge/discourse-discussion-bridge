# frozen_string_literal: true

class DiscussionBridgeSupportState < ActiveRecord::Base
  self.table_name = "discussion_bridge_support_states"
end

# == Schema Information
#
# Table name: discussion_bridge_support_states
#
#  id         :bigint           not null, primary key
#  enabled    :boolean          default(FALSE), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
