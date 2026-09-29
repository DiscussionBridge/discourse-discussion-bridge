# frozen_string_literal: true

require "rails_helper"
require "digest"
require "json"

RSpec.describe ActiveRecord::MigrationContext do
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

  def migration_context
    ActiveRecord::MigrationContext.new(migration_path)
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
