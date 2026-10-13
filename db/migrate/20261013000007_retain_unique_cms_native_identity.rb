# frozen_string_literal: true

class RetainUniqueCmsNativeIdentity < ActiveRecord::Migration[7.0]
  def change
    # Withdrawn/attention identities remain reserved. Existing ambiguity must
    # stop installation for reconciliation; migration never deduplicates rows.
    add_index :discussion_bridge_cms_mappings,
              %i[content_connection_id destination_native_id],
              unique: true,
              where: "destination_native_id IS NOT NULL",
              name: "idx_db_cms_mapping_native_identity"
  end
end
