# frozen_string_literal: true

class AddCorePublicationMetadata < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_bridge_records, :source_publication, :jsonb
    add_column :discussion_bridge_content_bindings, :presentation_mode, :string, limit: 16
  end
end
