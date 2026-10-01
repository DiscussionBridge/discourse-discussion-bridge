# frozen_string_literal: true

class RetainPublicationWorkIssueState < ActiveRecord::Migration[7.0]
  def up
    add_column :discussion_bridge_publication_works, :may_have_materialized, :boolean,
               null: false, default: false
    execute <<~SQL
      UPDATE discussion_bridge_publication_works
      SET may_have_materialized = TRUE
      WHERE leased_at IS NOT NULL
         OR lease_expires_at IS NOT NULL
         OR worker_id IS NOT NULL
         OR lease_token_digest IS NOT NULL
         OR stage_token_digest IS NOT NULL
         OR total_lease_seconds > 0
         OR last_acknowledged_stage IS NOT NULL
         OR synchronized_at IS NOT NULL
         OR deployed_at IS NOT NULL
         OR publicly_verified_at IS NOT NULL
         OR acknowledged_at IS NOT NULL
         OR attempt_count > 1
         OR retry_generation > 0
         OR next_retry_at IS NOT NULL
         OR failure_code IS NOT NULL
         OR failure_detail IS NOT NULL
         OR failed_at IS NOT NULL
         OR failure_request_digest IS NOT NULL
         OR failure_response_payload IS NOT NULL
         OR manual_retry_authorized_by_id IS NOT NULL
         OR manual_retry_authorized_at IS NOT NULL
         OR state IN (
           'leased',
           'awaiting_deployment',
           'awaiting_verification',
           'acknowledged',
           'retry_wait'
         )
         OR EXISTS (
           SELECT 1
           FROM discussion_bridge_publication_acknowledgements AS acknowledgement
           WHERE acknowledgement.publication_work_id = discussion_bridge_publication_works.id
         )
    SQL

    ambiguous = connection.select_values(<<~SQL)
      SELECT work_id
      FROM discussion_bridge_publication_works
      WHERE may_have_materialized = FALSE
      ORDER BY id
      LIMIT 21
    SQL
    if ambiguous.any?
      listed = ambiguous.first(20).join(", ")
      suffix = ambiguous.length > 20 ? ", ..." : ""
      raise ActiveRecord::MigrationError,
            "publication work issue state cannot be proven for #{listed}#{suffix}; " \
              "restore trustworthy pre-reset state from backup before retrying"
    end
  end

  def down
    execute <<~SQL
      LOCK TABLE discussion_bridge_publication_works IN ACCESS EXCLUSIVE MODE
    SQL
    retained = select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM discussion_bridge_publication_works
      WHERE may_have_materialized = TRUE
    SQL
    if retained.positive?
      raise ActiveRecord::MigrationError,
            "cannot remove retained publication issue state while issued work exists"
    end

    remove_column :discussion_bridge_publication_works, :may_have_materialized
  end
end
