# frozen_string_literal: true

class RetainPublicationFailureReceiptClock < ActiveRecord::Migration[7.0]
  def up
    # Unknown historical precision remains unknown; never infer it from SQL's
    # truncated timestamp. New receipts retain the actual receiver sample.
    add_column :discussion_bridge_publication_failures, :received_at_raw, :string, limit: 255
    add_column :discussion_bridge_publication_failures, :receipt_digest, :string, limit: 64
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM discussion_bridge_publication_failures WHERE received_at_raw IS NOT NULL OR receipt_digest IS NOT NULL)")
      raise ActiveRecord::IrreversibleMigration, "Retain exact receiver failure clocks"
    end
    remove_column :discussion_bridge_publication_failures, :received_at_raw
    remove_column :discussion_bridge_publication_failures, :receipt_digest
  end
end
