# frozen_string_literal: true

class ExpandAlpha21WireTimestamps < ActiveRecord::Migration[7.0]
  COLUMNS = {
    discussion_bridge_bridge_records: %i[source_created_at_wire source_updated_at_wire],
    discussion_bridge_content_bindings: %i[synchronized_at_wire deployed_at_wire publicly_verified_at_wire],
    discussion_bridge_publication_works: %i[
      synchronized_at_wire
      deployed_at_wire
      publicly_verified_at_wire
      failed_at_wire
    ],
  }.freeze

  def up
    COLUMNS.each do |table, columns|
      columns.each do |column|
        change_column table, column, :text if column_exists?(table, column)
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "accepted RFC 3339 precision cannot be safely narrowed after persistence"
  end
end
