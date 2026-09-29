# frozen_string_literal: true

class PreserveAlpha21WireTimestamps < ActiveRecord::Migration[7.0]
  def up
    %i[source_created_at_wire source_updated_at_wire].each do |column|
      add_column :discussion_bridge_bridge_records, column, :string, limit: 40 unless
        column_exists?(:discussion_bridge_bridge_records, column)
    end
    %i[synchronized_at_wire deployed_at_wire publicly_verified_at_wire].each do |column|
      add_column :discussion_bridge_content_bindings, column, :string, limit: 40 unless
        column_exists?(:discussion_bridge_content_bindings, column)
    end
    %i[synchronized_at_wire deployed_at_wire publicly_verified_at_wire failed_at_wire].each do |column|
      add_column :discussion_bridge_publication_works, column, :string, limit: 40 unless
        column_exists?(:discussion_bridge_publication_works, column)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "wire timestamp text preserves precision that database datetime columns cannot represent"
  end
end
