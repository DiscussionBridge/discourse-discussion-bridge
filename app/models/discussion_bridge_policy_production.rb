# frozen_string_literal: true

class DiscussionBridgePolicyProduction < ActiveRecord::Base
  self.table_name = "discussion_bridge_policy_productions"
  belongs_to :destination_policy, class_name: "DiscussionBridgeDestinationPolicy"
end

# == Schema Information
#
# Table name: discussion_bridge_policy_productions
#
#  id                    :bigint           not null, primary key
#  complete              :boolean          default(FALSE), not null
#  cut                   :bigint           not null
#  position              :bigint           default(0), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  destination_policy_id :bigint           not null
#
# Indexes
#
#  idx_db_policy_production  (destination_policy_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (destination_policy_id => discussion_bridge_destination_policies.id)
#
