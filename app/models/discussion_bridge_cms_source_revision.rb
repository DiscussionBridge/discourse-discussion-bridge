# frozen_string_literal: true

class DiscussionBridgeCmsSourceRevision < ActiveRecord::Base
  self.table_name = "discussion_bridge_cms_source_revisions"
  belongs_to :cms_source_intent, class_name: "DiscussionBridgeCmsSourceIntent"
  before_update { throw(:abort) }
  before_destroy { throw(:abort) }
end

# == Schema Information
#
# Table name: discussion_bridge_cms_source_revisions
#
#  id                   :bigint           not null, primary key
#  content_bytes_blob   :binary           not null
#  source_metadata      :jsonb            not null
#  source_revision      :string(128)      not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  cms_source_intent_id :bigint           not null
#
# Indexes
#
#  idx_db_cms_revision_intent_revision  (cms_source_intent_id,source_revision) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (cms_source_intent_id => discussion_bridge_cms_source_intents.id)
#
