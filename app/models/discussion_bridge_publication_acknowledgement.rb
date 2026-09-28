# frozen_string_literal: true

class DiscussionBridgePublicationAcknowledgement < ActiveRecord::Base
  self.table_name = "discussion_bridge_publication_acknowledgements"

  belongs_to :publication_work, class_name: "DiscussionBridgePublicationWork"

  validates :stage, inclusion: { in: ::DiscussionBridge::PublicationWorkProtocol::STAGES },
                    uniqueness: { scope: :publication_work_id }
  validates :request_digest, length: { is: 64 }
end

# == Schema Information
#
# Table name: discussion_bridge_publication_acknowledgements
#
#  id                  :bigint           not null, primary key
#  request_digest      :string(64)       not null
#  request_payload     :jsonb            not null
#  response_payload    :jsonb            not null
#  stage               :string(32)       not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  publication_work_id :bigint           not null
#
# Indexes
#
#  idx_db_publication_acks_stage  (publication_work_id,stage) UNIQUE
#  idx_db_publication_acks_work   (publication_work_id)
#
# Foreign Keys
#
#  fk_rails_...  (publication_work_id => discussion_bridge_publication_works.id)
#
