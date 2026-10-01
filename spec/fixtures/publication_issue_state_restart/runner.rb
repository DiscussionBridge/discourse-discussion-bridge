# frozen_string_literal: true

schema_name = ENV.fetch("DISCUSSION_BRIDGE_R3_F01_SCHEMA")
phase = ENV.fetch("DISCUSSION_BRIDGE_R3_F01_PHASE")
raise "invalid restart schema" unless /\Adb_r3_f01_restart_[a-f0-9]{12}\z/.match?(schema_name)

connection = ActiveRecord::Base.connection
plugin_root = File.expand_path("../../..", __dir__)
migration_path = File.join(plugin_root, "db/migrate")
historical_fixture = File.expand_path(
  "../historical_publication_work_registry/issue_and_expire_4841aab.rb",
  __dir__,
)
policy = {
  "destination_policy_id" => "destination:test:1",
  "profile" => "wordpress",
}

reset_models = lambda do
  [
    DiscussionBridgeBridgeRecord,
    DiscussionBridgeContentBinding,
    DiscussionBridgeContentConnection,
    DiscussionBridgePublicationWork,
    DiscussionBridgeSourceRevocation,
  ].each(&:reset_column_information)
end

original_search_path = connection.schema_search_path
begin
  case phase
  when "prepare"
    connection.execute("CREATE SCHEMA #{schema_name}")
    connection.schema_search_path = schema_name
    connection.schema_cache.clear!
    connection.execute <<~SQL
      CREATE TABLE users (id bigint PRIMARY KEY);
      CREATE TABLE topics (id bigint PRIMARY KEY);
      CREATE TABLE schema_migration_details (
        id serial PRIMARY KEY,
        version varchar NOT NULL,
        name varchar,
        hostname varchar,
        git_version varchar,
        rails_version varchar,
        duration integer,
        direction varchar,
        created_at timestamp NOT NULL
      );
      CREATE INDEX index_schema_migration_details_on_version
        ON schema_migration_details (version);
      INSERT INTO users (id) VALUES (1);
      INSERT INTO topics (id) VALUES (1);
    SQL
    context = ActiveRecord::MigrationContext.new(migration_path)
    context.up(20_260_929_000_003)
    now = connection.quote(Time.zone.parse("2026-09-29T12:00:00Z"))
    connection.execute <<~SQL
      INSERT INTO discussion_bridge_content_connections
        (id, public_id, name, platform, secret_digest, allowed_origins, allowed_directions,
         allowed_lanes, enabled, destination_policies, policy_revision, created_at, updated_at)
      VALUES (1, 'dbc_restart_test', 'Restart recovery', 'wordpress', '#{"a" * 64}',
              '["https://source.example"]', '["from_discourse"]', '["article"]', true,
              #{connection.quote(JSON.generate([policy]))}::jsonb,
              'policy:issued:1', #{now}, #{now});
      INSERT INTO discussion_bridge_bridge_records
        (id, resource_id, direction, state, title, topic_id, lane, created_at, updated_at)
      VALUES (1, 'dbr_restart_test', 'from_discourse', 'active', 'Restart recovery', 1,
              'article', #{now}, #{now});
      INSERT INTO discussion_bridge_content_bindings
        (id, bridge_record_id, content_connection_id, role, state, external_id,
         canonical_url, identity_digest, canonical_url_digest, binding_id, created_at, updated_at)
      VALUES (1, 1, 1, 'presentation', 'active', 'restart-test',
              'https://source.example/restart-test', '#{"b" * 64}', '#{"c" * 64}',
              'dbb_#{"d" * 32}', #{now}, #{now});
      INSERT INTO discussion_bridge_publication_works
        (id, content_connection_id, bridge_record_id, content_binding_id, work_id, action, state,
         source_revision, source_revision_sequence, policy_revision, destination_policy_id,
         catalog_revision, presentation_mode, resolved_container, resolved_taxonomy,
         resolved_author, native_limit_policy, created_at, updated_at)
      VALUES (1, 1, 1, 1, 'dbw_#{"e" * 32}', 'publish', 'available',
              'revision:1', 1, 'policy:issued:1', 'destination:test:1',
              'catalog:test:1', 'interactive',
              '{"id":"site:articles","kind":"post_type"}', '[]',
              '{"mode":"source_attribution","destination_id":"author:editor"}',
              '{"maximum_bytes":49152,"overflow_behavior":"excerpt_with_read_more"}',
              #{now}, #{now});
    SQL

    require historical_fixture
    historical_work = Class.new(ActiveRecord::Base) do
      self.table_name = "discussion_bridge_publication_works"
    end
    historical_work.reset_column_information
    historical_connection = Data.define(:publication_works).new(
      historical_work.where(content_connection_id: 1),
    )
    historical_registry = DiscussionBridge::HistoricalPublicationWorkRegistry4841aab.new(
      connection: historical_connection,
    )
    issued_at = Time.zone.parse("2026-09-29T12:05:00Z")
    claim = historical_registry.claim_one(
      historical_work.find(1),
      worker_id: "historical-restart-worker",
      lease_seconds: 300,
      now: issued_at,
    )
    raise "historical claim failed" unless claim&.work&.reload&.state == "leased"

    connection.execute <<~SQL
      CREATE TABLE r3_f01_issue_backup AS
      SELECT * FROM discussion_bridge_publication_works WHERE id = 1;
    SQL
    historical_registry.reconcile_expired!(issued_at + 300.seconds)
    reset_work = historical_work.find(1)
    raise "historical reset failed" unless
      reset_work.state == "available" && reset_work.attempt_count == 1 &&
        reset_work.leased_at.nil? && reset_work.lease_token_digest.nil?
    connection.execute <<~SQL
      UPDATE discussion_bridge_publication_works
      SET state = 'operator_attention',
          resolution_error = 'destination_unavailable',
          updated_at = created_at
      WHERE id = 1
    SQL

    rejected = false
    begin
      ActiveRecord::MigrationContext.new(migration_path).up(20_260_929_000_004)
    rescue StandardError => error
      rejected = error.message.include?("issue state cannot be proven")
    end
    raise "ambiguous historical migration was not rejected" unless rejected
    raise "failed migration retained its new column" if
      connection.column_exists?(:discussion_bridge_publication_works, :may_have_materialized)
    puts "R3-F01 prepare complete"
  when "resume"
    connection.schema_search_path = schema_name
    connection.schema_cache.clear!
    connection.execute <<~SQL
      UPDATE discussion_bridge_publication_works AS work
      SET state = backup.state,
          worker_id = backup.worker_id,
          lease_token_digest = backup.lease_token_digest,
          stage_token_digest = backup.stage_token_digest,
          total_lease_seconds = backup.total_lease_seconds,
          leased_at = backup.leased_at,
          lease_expires_at = backup.lease_expires_at,
          available_at = backup.available_at,
          resolution_error = backup.resolution_error,
          updated_at = backup.updated_at
      FROM r3_f01_issue_backup AS backup
      WHERE work.id = backup.id
    SQL
    ActiveRecord::MigrationContext.new(migration_path).up(20_260_929_000_004)
    raise "restored issue proof was not retained" unless
      connection.select_value(<<~SQL)
        SELECT may_have_materialized
        FROM discussion_bridge_publication_works
        WHERE id = 1
      SQL

    reset_models.call
    migrated_connection = DiscussionBridgeContentConnection.find(1)
    migrated_record = DiscussionBridgeBridgeRecord.find(1)
    migrated_binding = DiscussionBridgeContentBinding.find(1)
    removed_policy_revision = "policy:removed:2"
    migrated_connection.update_columns(
      destination_policies: [],
      policy_revision: removed_policy_revision,
    )
    revocation = DiscussionBridgeSourceRevocation.create!(
      bridge_record: migrated_record,
      content_connection: migrated_connection,
      revocation_id: "dbr_#{"9" * 32}",
      source_revision: "revision:1",
      source_revision_sequence: 2,
      reason: "policy_removed",
      effective_at: Time.zone.now,
      restorable: true,
      affected_binding_ids: [migrated_binding.binding_id],
      policy_revision: removed_policy_revision,
    )
    DiscussionBridge::PublicationWorkRegistry.ensure_policy_withdrawal!(
      record: migrated_record,
      connection: migrated_connection,
      revocation: revocation,
      policies: [policy],
      policy_revision: removed_policy_revision,
    )
    withdrawal = migrated_connection.publication_works.where(action: "unpublish").sole
    raise "withdrawal used the wrong destination" unless
      withdrawal.destination_policy_id == "destination:test:1" &&
        withdrawal.resolved_container == { "id" => "site:articles", "kind" => "post_type" }

    claimed = DiscussionBridge::PublicationWorkRegistry.claim(
      connection: migrated_connection,
      worker_id: "historical-restart-worker-2",
      maximum_items: 1,
      requested_lease_seconds: 300,
      correlation_id: "historical-restart-claim",
    ).sole
    synchronized_at = Time.zone.now.iso8601(6)
    DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: migrated_connection,
      work_id: claimed.fetch(:work_id),
      payload: {
        lease_token: claimed.fetch(:lease_token),
        resource_id: migrated_record.resource_id,
        source_revision: claimed.fetch(:source_revision),
        source_revision_sequence: claimed.fetch(:source_revision_sequence),
        policy_revision: claimed.fetch(:policy_revision),
        destination_policy_id: claimed.fetch(:destination_policy_id),
        action: claimed.fetch(:action),
        stage: "synchronized",
        stage_token: claimed.fetch(:stage_token),
        destination_binding: {
          binding_id: migrated_binding.binding_id,
          external_id: migrated_binding.external_id,
          canonical_url: migrated_binding.canonical_url,
          publication_revision: "historical-restart-withdrawal:1",
          content_disposition: "complete",
        },
        synchronized_at: synchronized_at,
        deployment_state: "not_required",
        verification_state: "not_required",
        correlation_id: "historical-restart-withdrawn",
      },
    )
    raise "withdrawal acknowledgement was not retained" unless withdrawal.reload.state == "acknowledged"
    puts "R3-F01 resume complete"
  when "verify"
    connection.schema_search_path = schema_name
    connection.schema_cache.clear!
    reset_models.call
    migrated_connection = DiscussionBridgeContentConnection.find(1)
    migrated_record = DiscussionBridgeBridgeRecord.find(1)
    revocation = DiscussionBridgeSourceRevocation.find_by!(reason: "policy_removed")
    original = migrated_connection.publication_works.find_by!(work_id: "dbw_#{"e" * 32}")
    withdrawal = migrated_connection.publication_works.where(action: "unpublish").sole
    raise "retained issue state disappeared after restart" unless original.may_have_materialized
    raise "acknowledged withdrawal disappeared after restart" unless withdrawal.state == "acknowledged"
    DiscussionBridge::PublicationWorkRegistry.ensure_policy_withdrawal!(
      record: migrated_record,
      connection: migrated_connection,
      revocation: revocation,
      policies: [policy],
      policy_revision: "policy:removed:2",
    )
    raise "restart created duplicate cleanup" unless
      migrated_connection.publication_works.where(action: "unpublish").count == 1
    puts "R3-F01 verify complete"
  when "cleanup"
    connection.schema_search_path = original_search_path
    connection.execute("DROP SCHEMA IF EXISTS #{schema_name} CASCADE")
    puts "R3-F01 cleanup complete"
  else
    raise "unknown restart phase"
  end
ensure
  connection.schema_search_path = original_search_path
  connection.schema_cache.clear!
  reset_models.call
end
