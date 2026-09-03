# frozen_string_literal: true

class BackfillFromDiscourseRecordLanes < ActiveRecord::Migration[7.0]
  def up
    execute <<~SQL
      UPDATE discussion_bridge_bridge_records AS records
      SET lane = connections.allowed_lanes ->> 0,
          updated_at = CURRENT_TIMESTAMP
      FROM discussion_bridge_content_bindings AS bindings
      INNER JOIN discussion_bridge_content_connections AS connections
        ON connections.id = bindings.content_connection_id
      WHERE bindings.bridge_record_id = records.id
        AND records.direction = 'from_discourse'
        AND (records.lane IS NULL OR records.lane = '')
        AND bindings.role = 'presentation'
        AND bindings.state = 'active'
        AND jsonb_array_length(connections.allowed_lanes) = 1
        AND (
          SELECT COUNT(*)
          FROM discussion_bridge_content_bindings AS active_bindings
          WHERE active_bindings.bridge_record_id = records.id
            AND active_bindings.role = 'presentation'
            AND active_bindings.state = 'active'
        ) = 1
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "From Discourse lane provenance cannot be removed safely"
  end
end
