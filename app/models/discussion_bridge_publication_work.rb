# frozen_string_literal: true

class DiscussionBridgePublicationWork < ActiveRecord::Base
  self.table_name = "discussion_bridge_publication_works"
  belongs_to :publication_destination, class_name: "DiscussionBridgePublicationDestination"
  belongs_to :source_inventory_entry, class_name: "DiscussionBridgeSourceInventoryEntry"
  belongs_to :destination_policy, class_name: "DiscussionBridgeDestinationPolicy"

  IMMUTABLE = %w[publication_destination_id source_inventory_entry_id destination_policy_id public_id identity_digest context_digest context destination_mode].freeze
  before_update do
    raise ActiveRecord::ReadOnlyRecord if IMMUTABLE.any? { |field| will_save_change_to_attribute?(field) }
  end
  before_destroy { raise ActiveRecord::ReadOnlyRecord }
end

# == Schema Information
#
# Table name: discussion_bridge_publication_works
#
#  id                         :bigint           not null, primary key
#  attempt_count              :integer          default(1), not null
#  context                    :jsonb            not null
#  context_digest             :string(64)       not null
#  destination_mode           :string(16)
#  identity_digest            :string(64)       not null
#  lease_expires_at           :datetime
#  lease_started_at           :datetime
#  lease_token                :string(64)
#  next_retry_at              :datetime
#  retry_generation           :integer          default(0), not null
#  retry_resume_state         :string(32)
#  stage_token                :string(64)
#  state                      :string(32)       default("available"), not null
#  total_lease_seconds        :integer          default(0), not null
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  destination_policy_id      :bigint           not null
#  public_id                  :string(36)       not null
#  publication_destination_id :bigint           not null
#  source_inventory_entry_id  :bigint           not null
#  worker_id                  :string(200)
#
# Indexes
#
#  idx_db_work_destination  (publication_destination_id,id)
#  idx_db_work_expiry       (state,lease_expires_at,id)
#  idx_db_work_identity     (identity_digest) UNIQUE
#  idx_db_work_public       (public_id) UNIQUE
#  idx_db_work_retry_due    (state,next_retry_at,id)
#
# Foreign Keys
#
#  fk_rails_...  (destination_policy_id => discussion_bridge_destination_policies.id)
#  fk_rails_...  (publication_destination_id => discussion_bridge_publication_destinations.id)
#  fk_rails_...  (source_inventory_entry_id => discussion_bridge_source_inventory_entries.id)
#
