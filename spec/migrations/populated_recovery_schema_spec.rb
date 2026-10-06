# frozen_string_literal: true

require "rails_helper"
require "digest"
require "json"
require "rbconfig"
require "timeout"
require_relative "../support/discussion_bridge_bounded_subprocess"

RSpec.describe ActiveRecord::MigrationContext do
  include DiscussionBridge::SpecSupport::BoundedSubprocess

  self.use_transactional_tests = false

  ALPHA_30_COMMIT = "9e64b4a83d5fd439ffa19e59edbc9682adb2c536"
  LATER_EXPERIMENTAL_COMMIT = "95171ff6b1c09d72d8fe274c3c0d594ca1d613a0"
  OPERATOR_ID = 1
  TOPIC_ID = 1

  let(:connection) { ActiveRecord::Base.connection }
  let(:schema_name) { "db_recovery_#{SecureRandom.hex(6)}" }
  let(:migration_path) { File.expand_path("../../db/migrate", __dir__) }

  around do |example|
    original_search_path = connection.schema_search_path
    original_migration_verbosity = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    connection.execute("CREATE SCHEMA #{schema_name}")
    connection.schema_search_path = schema_name
    connection.schema_cache.clear!
    execute_batch <<~SQL
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
      INSERT INTO users (id) VALUES (#{OPERATOR_ID});
      INSERT INTO topics (id) VALUES (#{TOPIC_ID});
    SQL
    example.run
  ensure
    ActiveRecord::Migration.verbose = original_migration_verbosity
    connection.schema_search_path = original_search_path
    connection.schema_cache.clear!
    connection.execute("DROP SCHEMA IF EXISTS #{schema_name} CASCADE")
    reset_recovery_model_columns!
  end

  it "preserves a populated exact Alpha.30 baseline through a clean and repeated migration" do
    migrate_historical("alpha30", ALPHA_30_COMMIT)
    seed_baseline_rows
    retained = retained_state
    expect_retained_snapshot_coverage(
      retained,
      %w[
        discussion_bridge_audit_events
        discussion_bridge_bridge_records
        discussion_bridge_content_bindings
        discussion_bridge_content_connections
      ],
    )

    migrate
    expect_retained_state(retained)
    connection.execute(
      "UPDATE discussion_bridge_content_connections SET secret_digest = '#{"f" * 64}' WHERE id = 1",
    )
    expect { expect_retained_state(retained) }.to raise_error(
      RSpec::Expectations::ExpectationNotMetError,
      /retained data changed in discussion_bridge_content_connections/,
    )
    connection.execute(
      "UPDATE discussion_bridge_content_connections SET secret_digest = '#{"a" * 64}' WHERE id = 1",
    )
    expect_retained_state(retained)
    before_repeat = recovery_census
    migrate

    expect(recovery_census).to eq(before_repeat)
    expect(recovery_census).to include(
      "connections" => 1,
      "records" => 1,
      "bindings" => 1,
      "audit_events" => 1,
      "source_revisions" => 0,
      "publication_works" => 0,
    )
    expect(select_value("SELECT binding_id FROM discussion_bridge_content_bindings WHERE id = 1")).to match(
      /\Adbb_[0-9a-f]{32}\z/,
    )
    expect(select_value("SELECT title FROM discussion_bridge_bridge_records WHERE id = 1")).to eq(
      "Alpha.30 retained record",
    )
  end

  it "preserves populated later experimental state and resumes after a partial migration" do
    migrate_historical("later_experimental", LATER_EXPERIMENTAL_COMMIT)
    seed_baseline_rows
    seed_experimental_rows
    retained = retained_state
    expect_retained_snapshot_coverage(
      retained,
      %w[
        discussion_bridge_audit_events
        discussion_bridge_bridge_records
        discussion_bridge_content_bindings
        discussion_bridge_content_connections
        discussion_bridge_operator_events
        discussion_bridge_operator_services
        discussion_bridge_presentation_url_histories
        discussion_bridge_publication_overrides
        discussion_bridge_publication_work_items
        discussion_bridge_source_url_histories
      ],
    )

    migration_context.up(20_260_927_000_001)
    before_fault = retained_state
    create_calls = 0
    allow(connection).to receive(:create_table).and_wrap_original do |original, *arguments, **keywords, &block|
      result = original.call(*arguments, **keywords, &block)
      create_calls += 1
      raise "injected migration interruption" if create_calls == 2

      result
    end
    expect { migration_context.up(20_260_927_000_002) }.to raise_error(/injected migration interruption/)
    RSpec::Mocks.space.proxy_for(connection).reset
    expect(connection.table_exists?(:discussion_bridge_source_revisions)).to be(false)
    expect(connection.table_exists?(:discussion_bridge_source_snapshots)).to be(false)
    expect_retained_state(before_fault)

    migrate
    expect_retained_state(
      retained,
      except: { "discussion_bridge_publication_overrides" => %w[decision updated_at] },
    )

    expect(recovery_census).to include(
      "connections" => 1,
      "records" => 1,
      "bindings" => 1,
      "source_url_history" => 1,
      "presentation_url_history" => 1,
      "legacy_work_items" => 1,
      "legacy_operator_services" => 1,
      "legacy_operator_events" => 1,
      "source_revisions" => 0,
      "publication_works" => 0,
    )
    expect(select_value("SELECT decision FROM discussion_bridge_publication_overrides WHERE id = 1")).to eq(
      "include",
    )
    expect(
      select_value("SELECT updated_at FROM discussion_bridge_publication_overrides WHERE id = 1"),
    ).to be > Time.zone.parse("2026-09-23T12:00:00Z")
    expect(select_value("SELECT last_error_detail FROM discussion_bridge_publication_work_items WHERE id = 1")).to eq(
      "retained experimental evidence",
    )
    expect(select_value("SELECT installation_id FROM discussion_bridge_operator_services WHERE id = 1")).to eq(
      "legacy-installation",
    )
  end

  it "snapshots deployment mode only from the exact current policy revision" do
    migration_context.up(20_260_929_000_002)
    seed_publication_work_for_mode(
      connection_policy_revision: "policy:exact:1",
      work_policy_revision: "policy:exact:1",
      profile: "astro",
    )

    migration_context.up(20_260_929_000_003)

    expect(select_value("SELECT static_deployment FROM discussion_bridge_publication_works WHERE id = 1")).to eq(true)
  end

  it "refuses to invent deployment mode from a different current policy revision" do
    migration_context.up(20_260_929_000_002)
    seed_publication_work_for_mode(
      connection_policy_revision: "policy:current:2",
      work_policy_revision: "policy:issued:1",
      profile: "astro",
    )

    expect { migration_context.up(20_260_929_000_003) }.to raise_error(
      StandardError,
      /deployment mode cannot be proven/,
    )
  end

  it "rejects the exact historical issue and expiry-reset transition after it erased its proof" do
    migration_context.up(20_260_929_000_003)
    seed_publication_work_for_mode(
      connection_policy_revision: "policy:issued:1",
      work_policy_revision: "policy:issued:1",
      profile: "wordpress",
    )

    fixture_path = File.expand_path("../fixtures/historical_publication_work_registry", __dir__)
    manifest = JSON.parse(File.read(File.join(fixture_path, "MANIFEST.json")))
    expect(manifest.fetch("source_commit")).to eq("4841aab89eee3d0927c43ff01da44eae956aae55")
    expect(manifest.fetch("source_blob_sha1")).to eq("00e90703c4cb663125a7bb3b80f51641bd61598e")
    fixture_file = File.join(fixture_path, manifest.fetch("fixture"))
    expect(Digest::SHA256.hexdigest(File.binread(fixture_file))).to eq(manifest.fetch("fixture_sha256"))
    require fixture_file

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
      worker_id: "historical-worker",
      lease_seconds: 300,
      now: issued_at,
    )
    expect(claim.work.reload.state).to eq("leased")
    expect(claim.work.lease_token_digest).to be_present
    expect(claim.work.stage_token_digest).to be_present

    reset_at = issued_at + 300.seconds
    historical_registry.reconcile_expired!(reset_at)
    reset_work = historical_work.find(1)
    expect(reset_work.state).to eq("available")
    expect(reset_work.attempt_count).to eq(1)
    expect(reset_work.attributes.values_at(
      "worker_id",
      "lease_token_digest",
      "stage_token_digest",
      "leased_at",
      "lease_expires_at",
    )).to all(be_nil)
    expect(reset_work.total_lease_seconds).to eq(0)

    connection.execute <<~SQL
      UPDATE discussion_bridge_publication_works
      SET state = 'operator_attention',
          resolution_error = 'destination_unavailable',
          updated_at = created_at
      WHERE id = 1
    SQL
    reset_state = retained_state

    2.times do
      expect { migration_context.up(20_260_929_000_004) }.to raise_error(
        StandardError,
        /issue state cannot be proven for dbw_#{"e" * 32}.*restore trustworthy pre-reset state from backup/,
      )
      expect(connection.column_exists?(:discussion_bridge_publication_works, :may_have_materialized)).to be(false)
      expect_retained_state(reset_state)
    end

    restored_issued_at = connection.quote(issued_at)
    connection.execute <<~SQL
      UPDATE discussion_bridge_publication_works
      SET leased_at = #{restored_issued_at}
      WHERE id = 1
    SQL
    migration_context.up(20_260_929_000_004)
    expect(select_value(<<~SQL)).to eq(true)
      SELECT may_have_materialized
      FROM discussion_bridge_publication_works
      WHERE id = 1
    SQL

    reset_recovery_model_columns!
    migrated_connection = DiscussionBridgeContentConnection.find(1)
    migrated_record = DiscussionBridgeBridgeRecord.find(1)
    migrated_binding = DiscussionBridgeContentBinding.find(1)
    removed_policies = migrated_connection.destination_policies.deep_dup
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
      policies: removed_policies,
      policy_revision: removed_policy_revision,
    )
    withdrawal = migrated_connection.publication_works.where(action: "unpublish").sole
    expect(withdrawal).to have_attributes(
      destination_policy_id: "destination:test:1",
      static_deployment: false,
      state: "available",
    )

    claimed = DiscussionBridge::PublicationWorkRegistry.claim(
      connection: migrated_connection,
      worker_id: "historical-recovery-worker",
      maximum_items: 1,
      requested_lease_seconds: 300,
      correlation_id: "historical-recovery-claim",
    ).sole
    synchronized_at = Time.zone.now.iso8601(6)
    result = DiscussionBridge::PublicationWorkRegistry.acknowledge(
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
          publication_revision: "historical-withdrawal:1",
          content_disposition: "complete",
        },
        synchronized_at: synchronized_at,
        deployment_state: "not_required",
        verification_state: "not_required",
        correlation_id: "historical-recovery-withdrawn",
      },
    )
    expect(result).to include(work_id: withdrawal.work_id, accepted_stage: "synchronized")
    expect(withdrawal.reload.state).to eq("acknowledged")

    DiscussionBridge::PublicationWorkRegistry.ensure_policy_withdrawal!(
      record: migrated_record,
      connection: migrated_connection,
      revocation: revocation,
      policies: removed_policies,
      policy_revision: removed_policy_revision,
    )
    expect(migrated_connection.publication_works.where(action: "unpublish").count).to eq(1)
  end

  context "with historical issue recovery across fresh process boots", :fresh_process,
          order: :defined do
    # The ordered examples intentionally share only the external schema name;
    # every phase itself runs in a separate Rails process.
    # rubocop:disable RSpec/BeforeAfterAll
    before(:context) { @restart_schema = "db_r3_f01_restart_#{SecureRandom.hex(6)}" }

    after(:context) do
      stdout, stderr, status = run_restart_phase(@restart_schema, "cleanup")
      raise "cleanup failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}" unless status.success?
    end
    # rubocop:enable RSpec/BeforeAfterAll

    {
      "prepare" => /R3-F01 prepare complete/,
      "resume" => /R3-F01 resume complete/,
      "verify" => /R3-F01 verify complete/,
    }.each do |phase, expected_output|
      it "completes the #{phase} fresh-process phase" do
        stdout, stderr, status = run_restart_phase(@restart_schema, phase)
        expect(status).to be_success, "#{phase} failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
        expect(stdout).to match(expected_output)
      end
    end
  end

  it "backfills surviving issue proof and refuses to discard it on downgrade" do
    migration_context.up(20_260_929_000_003)
    seed_publication_work_for_mode(
      connection_policy_revision: "policy:issued:1",
      work_policy_revision: "policy:issued:1",
      profile: "astro",
    )
    retried_at = connection.quote(Time.zone.parse("2026-09-29T12:10:00Z"))
    connection.execute <<~SQL
      UPDATE discussion_bridge_publication_works
      SET attempt_count = 2,
          available_at = #{retried_at},
          updated_at = #{retried_at}
      WHERE id = 1
    SQL

    migration_context.up(20_260_929_000_004)

    expect(select_value(<<~SQL)).to eq(true)
      SELECT may_have_materialized
      FROM discussion_bridge_publication_works
      WHERE id = 1
    SQL
    expect { migration_context.down(20_260_929_000_003) }.to raise_error(
      StandardError,
      /cannot remove retained publication issue state/,
    )
    expect(select_value("SELECT may_have_materialized FROM discussion_bridge_publication_works WHERE id = 1")).to eq(
      true,
    )
  end

  it "excludes a concurrent issue-state write before deciding a downgrade is safe" do
    migration_context.up(20_260_929_000_004)
    seed_publication_work_for_mode(
      connection_policy_revision: "policy:queued:1",
      work_policy_revision: "policy:queued:1",
      profile: "astro",
    )
    lock_acquired = Queue.new
    writer_done = Queue.new
    writer_error = nil
    allow(connection).to receive(:select_value).and_wrap_original do |original, sql, *arguments|
      if sql.include?("may_have_materialized = TRUE")
        lock_acquired << true
        Timeout.timeout(5) { writer_done.pop }
      end
      original.call(sql, *arguments)
    end
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |writer_connection|
        original_search_path = writer_connection.schema_search_path
        writer_connection.schema_search_path = schema_name
        begin
          Timeout.timeout(5) { lock_acquired.pop }
          writer_connection.execute("SET lock_timeout = '250ms'")
          writer_connection.execute <<~SQL
            UPDATE discussion_bridge_publication_works
            SET may_have_materialized = TRUE
            WHERE id = 1
          SQL
        rescue StandardError => error
          writer_error = error
        ensure
          writer_connection.execute("RESET lock_timeout")
          writer_connection.schema_search_path = original_search_path
          writer_done << true
        end
      end
    end

    begin
      migration_context.down(20_260_929_000_003)
    ensure
      unless writer.join(5)
        writer.kill
        writer.join
        raise "concurrent downgrade writer did not terminate"
      end
    end

    expect(writer_error).to be_present
    expect(writer_error.message).to match(/lock timeout|canceling statement due to lock timeout/)
    expect(connection.column_exists?(:discussion_bridge_publication_works, :may_have_materialized)).to be(false)
  end

  it "does not infer that a marker-free legacy available row was never issued" do
    migration_context.up(20_260_929_000_003)
    seed_publication_work_for_mode(
      connection_policy_revision: "policy:queued:1",
      work_policy_revision: "policy:queued:1",
      profile: "astro",
    )

    expect { migration_context.up(20_260_929_000_004) }.to raise_error(
      StandardError,
      /issue state cannot be proven for dbw_#{"e" * 32}/,
    )
    expect(connection.column_exists?(:discussion_bridge_publication_works, :may_have_materialized)).to be(false)
  end

  it "rolls back positive backfill together with an ambiguous row and its migration version" do
    migration_context.up(20_260_929_000_003)
    seed_publication_work_for_mode(
      connection_policy_revision: "policy:mixed:1",
      work_policy_revision: "policy:mixed:1",
      profile: "astro",
    )
    connection.execute <<~SQL
      UPDATE discussion_bridge_publication_works
      SET attempt_count = 2
      WHERE id = 1;
      INSERT INTO discussion_bridge_publication_works
        (id, content_connection_id, bridge_record_id, content_binding_id, work_id, action, state,
         source_revision, source_revision_sequence, policy_revision, destination_policy_id,
         catalog_revision, presentation_mode, created_at, updated_at)
      VALUES (2, 1, 1, 1, 'dbw_#{"f" * 32}', 'update', 'available',
              'revision:2', 2, 'policy:mixed:1', 'destination:test:1',
              'catalog:test:1', 'interactive', NOW(), NOW())
    SQL
    retained = retained_state

    expect { migration_context.up(20_260_929_000_004) }.to raise_error(
      StandardError,
      /issue state cannot be proven for dbw_#{"f" * 32}/,
    )

    expect(connection.column_exists?(:discussion_bridge_publication_works, :may_have_materialized)).to be(false)
    expect_retained_state(retained)
    expect(select_value(<<~SQL).to_i).to eq(0)
      SELECT COUNT(*)
      FROM schema_migrations
      WHERE version = '20260929000004'
    SQL
  end

  it "fails closed for an unexplained marker-free historical state" do
    migration_context.up(20_260_929_000_003)
    seed_publication_work_for_mode(
      connection_policy_revision: "policy:unknown:1",
      work_policy_revision: "policy:unknown:1",
      profile: "astro",
    )
    connection.execute <<~SQL
      UPDATE discussion_bridge_publication_works
      SET state = 'future_unknown_state'
      WHERE id = 1
    SQL

    expect { migration_context.up(20_260_929_000_004) }.to raise_error(
      StandardError,
      /issue state cannot be proven for dbw_#{"e" * 32}/,
    )
    expect(connection.column_exists?(:discussion_bridge_publication_works, :may_have_materialized)).to be(false)
  end

  def migration_context
    ActiveRecord::MigrationContext.new(migration_path)
  end

  def reset_recovery_model_columns!
    [
      DiscussionBridgeBridgeRecord,
      DiscussionBridgeContentBinding,
      DiscussionBridgeContentConnection,
      DiscussionBridgePublicationWork,
      DiscussionBridgeSourceRevocation,
    ].each(&:reset_column_information)
  end

  def run_restart_phase(restart_schema, phase)
    runner = File.expand_path(
      "../fixtures/publication_issue_state_restart/runner.rb",
      __dir__,
    )
    environment = {
      "DISABLE_BOOTSNAP" => "1",
      "DISCUSSION_BRIDGE_R3_F01_PHASE" => phase,
      "DISCUSSION_BRIDGE_R3_F01_SCHEMA" => restart_schema,
      "LOAD_PLUGINS" => "1",
      "RAILS_ENV" => "test",
    }
    run_bounded_subprocess(
      environment,
      RbConfig.ruby,
      Rails.root.join("bin/rails").to_s,
      "runner",
      runner,
      chdir: Rails.root.to_s,
    )
  end

  def migrate
    migration_context.migrate
  end

  def migrate_historical(name, expected_commit)
    path = File.expand_path("../fixtures/historical_migrations/#{name}", __dir__)
    manifest = JSON.parse(File.read(File.join(path, "MANIFEST.json")))
    expect(manifest.fetch("commit")).to eq(expected_commit)
    expect(manifest.fetch("files")).not_to be_empty
    manifest.fetch("files").each do |entry|
      bytes = File.binread(File.join(path, entry.fetch("file")))
      expect(Digest::SHA256.hexdigest(bytes)).to eq(entry.fetch("sha256"))
    end
    ActiveRecord::MigrationContext.new(path).migrate
  end

  def retained_state
    connection.tables.grep(/\Adiscussion_bridge_/).sort.to_h do |table|
      rows = connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a
      [table, rows]
    end
  end

  def expect_retained_snapshot_coverage(snapshot, required_populated_tables)
    expect(snapshot).not_to be_empty
    expect(snapshot.keys).to include(*required_populated_tables)
    required_populated_tables.each do |table|
      expect(snapshot.fetch(table)).not_to be_empty, "retained snapshot has no rows for #{table}"
      expect(snapshot.fetch(table).first.keys).to match_array(connection.columns(table).map(&:name))
    end
  end

  def expect_retained_state(before, except: {})
    before.each do |table, rows|
      columns = (rows.first&.keys || connection.columns(table).map(&:name)) - Array(except[table])
      current = connection.select_all("SELECT #{columns.join(", ")} FROM #{table} ORDER BY id").to_a
      expected = rows.map { |row| row.except(*Array(except[table])) }
      expect(current).to eq(expected), "retained data changed in #{table}"
    end
  end
  def seed_baseline_rows
    now = connection.quote(Time.zone.parse("2026-09-14T12:00:00Z"))
    connection.execute <<~SQL
      INSERT INTO discussion_bridge_content_connections
        (id, public_id, name, platform, secret_digest, allowed_origins, allowed_directions,
         allowed_lanes, enabled, created_at, updated_at)
      VALUES (1, 'dbc_alpha30', 'Alpha.30 retained connection', 'astro', '#{"a" * 64}',
              '["https://source.example"]', '["from_discourse"]', '["article"]', true, #{now}, #{now});
      INSERT INTO discussion_bridge_bridge_records
        (id, resource_id, direction, state, title, topic_id, lane, source_authors,
         created_at, updated_at)
      VALUES (1, 'dbr_alpha30', 'from_discourse', 'active', 'Alpha.30 retained record', #{TOPIC_ID},
              'article', '[]', #{now}, #{now});
      INSERT INTO discussion_bridge_content_bindings
        (id, bridge_record_id, content_connection_id, role, state, external_id,
         canonical_url, identity_digest, canonical_url_digest, native_materialization,
         created_at, updated_at)
      VALUES (1, 1, 1, 'presentation', 'active', 'alpha30-page',
              'https://source.example/alpha30', '#{"b" * 64}', '#{"c" * 64}', true, #{now}, #{now});
      INSERT INTO discussion_bridge_audit_events
        (id, correlation_id, connection_id, source_identity_digest, topic_id, outcome,
         reason, requested_state, effective_state, created_at, updated_at)
      VALUES (1, 'alpha30/audit', 'dbc_alpha30', '#{"d" * 64}', #{TOPIC_ID}, 'accepted',
              'retained', '{}', '{}', #{now}, #{now});
    SQL
  end

  def seed_experimental_rows
    now = connection.quote(Time.zone.parse("2026-09-23T12:00:00Z"))
    connection.execute <<~SQL
      INSERT INTO discussion_bridge_source_url_histories
        (id, bridge_record_id, content_binding_id, verified_by_id, old_canonical_url,
         new_canonical_url, old_canonical_url_digest, redirect_status, verified_at, created_at, updated_at)
      VALUES (1, 1, 1, #{OPERATOR_ID}, 'https://old.example/source',
              'https://source.example/alpha30', '#{"e" * 64}', 301, #{now}, #{now}, #{now});
      INSERT INTO discussion_bridge_presentation_url_histories
        (id, bridge_record_id, content_binding_id, verified_by_id, old_canonical_url,
         new_canonical_url, old_canonical_url_digest, redirect_status, verified_at, created_at, updated_at)
      VALUES (1, 1, 1, #{OPERATOR_ID}, 'https://old.example/presentation',
              'https://source.example/alpha30', '#{"f" * 64}', 301, #{now}, #{now}, #{now});
      INSERT INTO discussion_bridge_publication_overrides
        (id, content_connection_id, topic_id, set_by_id, decision, created_at, updated_at)
      VALUES (1, 1, #{TOPIC_ID}, #{OPERATOR_ID}, 'publish', #{now}, #{now});
      INSERT INTO discussion_bridge_publication_work_items
        (id, content_connection_id, topic_id, bridge_record_id, action, state, attempt_count,
         last_error_detail, created_at, updated_at)
      VALUES (1, 1, #{TOPIC_ID}, 1, 'publish', 'failed', 2,
              'retained experimental evidence', #{now}, #{now});
      INSERT INTO discussion_bridge_operator_services
        (id, installation_id, enrollment_id, entitlement_payload, created_at, updated_at)
      VALUES (1, 'legacy-installation', 'legacy-enrollment', '{"retained":true}', #{now}, #{now});
      INSERT INTO discussion_bridge_operator_events
        (id, operator_service_id, actor_user_id, topic_id, content_connection_id,
         bridge_record_id, event_type, outcome, details, created_at)
      VALUES (1, 1, #{OPERATOR_ID}, #{TOPIC_ID}, 1, 1, 'legacy_event', 'retained',
              '{"retained":true}', #{now});
    SQL
  end

  def seed_publication_work_for_mode(connection_policy_revision:, work_policy_revision:, profile:)
    now = connection.quote(Time.zone.parse("2026-09-29T12:00:00Z"))
    policy = [
      {
        destination_policy_id: "destination:test:1",
        profile: profile,
      },
    ]
    connection.execute <<~SQL
      INSERT INTO discussion_bridge_content_connections
        (id, public_id, name, platform, secret_digest, allowed_origins, allowed_directions,
         allowed_lanes, enabled, destination_policies, policy_revision, created_at, updated_at)
      VALUES (1, 'dbc_mode_test', 'Mode test', 'astro', '#{"a" * 64}',
              '["https://source.example"]', '["from_discourse"]', '["article"]', true,
              #{connection.quote(JSON.generate(policy))}::jsonb,
              #{connection.quote(connection_policy_revision)}, #{now}, #{now});
      INSERT INTO discussion_bridge_bridge_records
        (id, resource_id, direction, state, title, topic_id, lane, created_at, updated_at)
      VALUES (1, 'dbr_mode_test', 'from_discourse', 'active', 'Mode test', #{TOPIC_ID},
              'article', #{now}, #{now});
      INSERT INTO discussion_bridge_content_bindings
        (id, bridge_record_id, content_connection_id, role, state, external_id,
         canonical_url, identity_digest, canonical_url_digest, binding_id, created_at, updated_at)
      VALUES (1, 1, 1, 'presentation', 'active', 'mode-test',
              'https://source.example/mode-test', '#{"b" * 64}', '#{"c" * 64}',
              'dbb_#{"d" * 32}', #{now}, #{now});
      INSERT INTO discussion_bridge_publication_works
        (id, content_connection_id, bridge_record_id, content_binding_id, work_id, action, state,
         source_revision, source_revision_sequence, policy_revision, destination_policy_id,
         catalog_revision, presentation_mode, resolved_container, resolved_taxonomy,
         resolved_author, native_limit_policy, created_at, updated_at)
      VALUES (1, 1, 1, 1, 'dbw_#{"e" * 32}', 'publish', 'available',
              'revision:1', 1, #{connection.quote(work_policy_revision)}, 'destination:test:1',
              'catalog:test:1', 'interactive',
              '{"id":"site:articles","kind":"post_type"}', '[]',
              '{"mode":"source_attribution","destination_id":"author:editor"}',
              '{"maximum_bytes":49152,"overflow_behavior":"excerpt_with_read_more"}',
              #{now}, #{now});
    SQL
  end

  def recovery_census
    {
      "connections" => count("discussion_bridge_content_connections"),
      "records" => count("discussion_bridge_bridge_records"),
      "bindings" => count("discussion_bridge_content_bindings"),
      "audit_events" => count("discussion_bridge_audit_events"),
      "source_url_history" => optional_count("discussion_bridge_source_url_histories"),
      "presentation_url_history" => optional_count("discussion_bridge_presentation_url_histories"),
      "legacy_work_items" => optional_count("discussion_bridge_publication_work_items"),
      "legacy_operator_services" => optional_count("discussion_bridge_operator_services"),
      "legacy_operator_events" => optional_count("discussion_bridge_operator_events"),
      "source_revisions" => count("discussion_bridge_source_revisions"),
      "publication_works" => count("discussion_bridge_publication_works"),
    }
  end

  def count(table)
    select_value("SELECT COUNT(*) FROM #{table}").to_i
  end

  def optional_count(table)
    connection.table_exists?(table) ? count(table) : 0
  end

  def select_value(sql)
    connection.select_value(sql)
  end

  def execute_batch(sql)
    connection.execute(sql)
  end
end
