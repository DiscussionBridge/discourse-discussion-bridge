# frozen_string_literal: true

class RetainPublicationWorkIssueState < ActiveRecord::Migration[7.0]
  def up
    add_column :discussion_bridge_publication_works, :may_have_materialized, :boolean,
               null: false, default: false
    execute <<~SQL
      UPDATE discussion_bridge_publication_works
      SET may_have_materialized = TRUE
      WHERE leased_at IS NOT NULL
         OR last_acknowledged_stage IS NOT NULL
         OR state IN ('leased', 'awaiting_deployment', 'awaiting_verification', 'acknowledged')
    SQL
  end

  def down
    remove_column :discussion_bridge_publication_works, :may_have_materialized
  end
end
