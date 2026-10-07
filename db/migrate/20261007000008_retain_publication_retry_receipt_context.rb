# frozen_string_literal: true

class RetainPublicationRetryReceiptContext < ActiveRecord::Migration[7.0]
  def up
    add_column :discussion_bridge_publication_retries, :receipt_digest, :string, limit: 64
    # Prior unknown actor/clock context is not guessed or backfilled.
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM discussion_bridge_publication_retries WHERE receipt_digest IS NOT NULL)")
      raise ActiveRecord::IrreversibleMigration, "Retain exact operator Retry receipt context"
    end
    remove_column :discussion_bridge_publication_retries, :receipt_digest
  end
end
