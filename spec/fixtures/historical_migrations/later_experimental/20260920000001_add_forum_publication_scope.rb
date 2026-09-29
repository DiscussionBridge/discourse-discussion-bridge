# frozen_string_literal: true

class AddForumPublicationScope < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_content_connections, :forum_publication_enabled,
               :boolean, null: false, default: false
    add_column :discussion_bridge_content_connections, :publication_category_mode,
               :string, null: false, default: "all_except_selected", limit: 32
    add_column :discussion_bridge_content_connections, :publication_category_ids,
               :jsonb, null: false, default: []
    add_column :discussion_bridge_content_connections, :publication_excluded_category_ids,
               :jsonb, null: false, default: []
    add_column :discussion_bridge_content_connections, :publication_tag_mode,
               :string, null: false, default: "all", limit: 32
    add_column :discussion_bridge_content_connections, :publication_tag_ids,
               :jsonb, null: false, default: []
    add_column :discussion_bridge_content_connections, :publication_excluded_tag_ids,
               :jsonb, null: false, default: []
    add_column :discussion_bridge_content_connections, :publication_include_unlisted,
               :boolean, null: false, default: false
    add_column :discussion_bridge_content_connections, :platform_catalog,
               :jsonb, null: false, default: {}
    add_column :discussion_bridge_content_connections, :platform_catalog_revision,
               :string, limit: 64
    add_column :discussion_bridge_content_connections, :platform_catalog_display_revision,
               :string, limit: 64
    add_column :discussion_bridge_content_connections, :platform_catalog_adapter_id,
               :string, limit: 100
    add_column :discussion_bridge_content_connections, :platform_catalog_adapter_version,
               :string, limit: 100
    add_column :discussion_bridge_content_connections, :platform_catalog_observed_at, :datetime
    add_column :discussion_bridge_content_connections, :platform_catalog_refresh_requested_at, :datetime
    add_column :discussion_bridge_content_connections, :destination_mapping,
               :jsonb, null: false, default: {}
    add_column :discussion_bridge_content_connections, :destination_mapping_revision,
               :string, limit: 64
    add_column :discussion_bridge_content_connections, :destination_mapping_updated_at, :datetime

    add_column :discussion_bridge_bridge_records, :destination_state, :string, limit: 32
    add_column :discussion_bridge_bridge_records, :publication_program,
               :string, null: false, default: "legacy", limit: 32
    add_column :discussion_bridge_bridge_records, :acknowledged_source_revision, :string, limit: 128
    add_column :discussion_bridge_bridge_records, :acknowledged_publication_revision, :string, limit: 64
    add_column :discussion_bridge_bridge_records, :acknowledged_mapping_revision, :string, limit: 64
    add_column :discussion_bridge_bridge_records, :acknowledged_destination,
               :jsonb, null: false, default: {}
    add_column :discussion_bridge_bridge_records, :pending_publication_revision, :string, limit: 64
    add_column :discussion_bridge_bridge_records, :pending_mapping_revision, :string, limit: 64
    add_column :discussion_bridge_bridge_records, :pending_destination,
               :jsonb, null: false, default: {}
    add_column :discussion_bridge_bridge_records, :acknowledged_at, :datetime
    add_column :discussion_bridge_bridge_records, :last_delivery_outcome, :string, limit: 32
    add_column :discussion_bridge_bridge_records, :last_delivery_attempt_at, :datetime
    add_column :discussion_bridge_bridge_records, :delivery_attempt_count,
               :integer, null: false, default: 0
    add_column :discussion_bridge_bridge_records, :last_delivery_error_code, :string, limit: 64
    add_column :discussion_bridge_bridge_records, :last_delivery_error_detail, :string, limit: 1000
    add_column :discussion_bridge_bridge_records, :attempted_publication_revision, :string, limit: 64
    add_column :discussion_bridge_bridge_records, :attempted_mapping_revision, :string, limit: 64
    add_column :discussion_bridge_bridge_records, :attempted_destination,
               :jsonb, null: false, default: {}

    add_index :discussion_bridge_bridge_records, :destination_state,
              name: "idx_db_bridge_records_destination_state"
  end
end
