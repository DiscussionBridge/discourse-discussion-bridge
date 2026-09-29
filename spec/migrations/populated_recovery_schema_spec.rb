# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveRecord::MigrationContext do
  ALPHA_30_COMMIT = "9e64b4a83d5fd439ffa19e59edbc9682adb2c536"
  LATER_EXPERIMENTAL_COMMIT = "95171ff6b1c09d72d8fe274c3c0d594ca1d613a0"
  OPERATOR_ID = 1
  TOPIC_ID = 1
  BASELINE_VERSIONS = %w[
    20260802000001
    20260802000002
    20260803000001
    20260829000001
    20260830000001
    20260830000002
    20260831000001
    20260901000001
    20260903000001
    20260914000001
  ].freeze
  EXPERIMENTAL_VERSIONS = %w[
    20260915000001
    20260916000001
    20260917000001
    20260920000001
    20260920000002
    20260920000003
    20260922000001
    20260923000001
  ].freeze

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
    build_alpha_30_fixture
    seed_migration_versions(BASELINE_VERSIONS)
    seed_baseline_rows

    migrate
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
    build_alpha_30_fixture
    build_later_experimental_fixture
    seed_migration_versions(BASELINE_VERSIONS + EXPERIMENTAL_VERSIONS)
    seed_baseline_rows
    seed_experimental_rows

    migration_context.up(20_260_927_000_004)
    partial_census = recovery_census
    expect(partial_census).to include("records" => 1, "legacy_work_items" => 1)

    migrate

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

  def seed_migration_versions(versions)
    connection.execute("CREATE TABLE schema_migrations (version varchar NOT NULL PRIMARY KEY)")
    values = versions.map { |version| "(#{connection.quote(version)})" }.join(",")
    connection.execute("INSERT INTO schema_migrations (version) VALUES #{values}")
  end

  def build_alpha_30_fixture
    # This schema surface is transcribed from the migrations at ALPHA_30_COMMIT. The
    # provenance constants are deliberately executable evidence, not release inputs.
    expect(ALPHA_30_COMMIT).to eq("9e64b4a83d5fd439ffa19e59edbc9682adb2c536")
    execute_batch <<~SQL
      CREATE TABLE discussion_bridge_connections (
        id bigserial PRIMARY KEY, connection_id varchar NOT NULL,
        canonical_source_url text NOT NULL, source_identity_digest varchar(64) NOT NULL,
        state varchar NOT NULL DEFAULT 'reserved', reservation_token varchar(64), topic_id bigint,
        effective_actor_id bigint, lane varchar, requested_visibility varchar NOT NULL,
        effective_visibility varchar NOT NULL, requested_state jsonb NOT NULL DEFAULT '{}',
        effective_state jsonb NOT NULL DEFAULT '{}', retry_authorized_at timestamp,
        retry_authorized_by_id bigint, created_at timestamp NOT NULL, updated_at timestamp NOT NULL
      );
      CREATE TABLE discussion_bridge_audit_events (
        id bigserial PRIMARY KEY, correlation_id varchar, connection_id varchar NOT NULL,
        adapter_id varchar, source_identity_digest varchar(64) NOT NULL, topic_id bigint,
        effective_actor_id bigint, outcome varchar NOT NULL, reason varchar NOT NULL,
        requested_state jsonb NOT NULL DEFAULT '{}', effective_state jsonb NOT NULL DEFAULT '{}',
        created_at timestamp NOT NULL, updated_at timestamp NOT NULL
      );
      CREATE TABLE discussion_bridge_content_connections (
        id bigserial PRIMARY KEY, public_id varchar(64) NOT NULL, name varchar(120) NOT NULL,
        platform varchar(32) NOT NULL, secret_digest varchar(64) NOT NULL,
        allowed_origins jsonb NOT NULL DEFAULT '[]', allowed_directions jsonb NOT NULL DEFAULT '[]',
        allowed_lanes jsonb NOT NULL DEFAULT '[]', adapter_id varchar(100), adapter_version varchar(100),
        last_seen_at timestamp, enabled boolean NOT NULL DEFAULT true, author_mode varchar(32),
        fixed_author_id bigint, default_source_author_id bigint, fallback_author_mode varchar(32),
        fallback_author_id bigint, topic_toc_enabled boolean NOT NULL DEFAULT false,
        default_category_id bigint, created_at timestamp NOT NULL, updated_at timestamp NOT NULL
      );
      CREATE TABLE discussion_bridge_bridge_records (
        id bigserial PRIMARY KEY, resource_id varchar(64) NOT NULL, direction varchar(32) NOT NULL,
        state varchar(32) NOT NULL DEFAULT 'reserved', title varchar(1024) NOT NULL, topic_id bigint,
        effective_actor_id bigint, lane varchar(64), requested_visibility varchar(32) NOT NULL DEFAULT 'unlisted',
        effective_visibility varchar(32) NOT NULL DEFAULT 'unlisted', reservation_token varchar(64),
        retry_authorized_at timestamp, retry_authorized_by_id bigint,
        source_authors jsonb NOT NULL DEFAULT '[]', primary_source_author_id varchar(255),
        created_at timestamp NOT NULL, updated_at timestamp NOT NULL
      );
      CREATE TABLE discussion_bridge_content_bindings (
        id bigserial PRIMARY KEY, bridge_record_id bigint NOT NULL, content_connection_id bigint NOT NULL,
        role varchar(32) NOT NULL, state varchar(32) NOT NULL DEFAULT 'active', external_id varchar(255) NOT NULL,
        canonical_url text NOT NULL, identity_digest varchar(64) NOT NULL, canonical_url_digest varchar(64) NOT NULL,
        activated_at timestamp, retired_at timestamp, native_materialization boolean NOT NULL DEFAULT false,
        created_at timestamp NOT NULL, updated_at timestamp NOT NULL
      );
    SQL
  end

  def build_later_experimental_fixture
    expect(LATER_EXPERIMENTAL_COMMIT).to eq("95171ff6b1c09d72d8fe274c3c0d594ca1d613a0")
    execute_batch <<~SQL
      ALTER TABLE discussion_bridge_content_connections
        ADD COLUMN include_source_in_published_url boolean NOT NULL DEFAULT false,
        ADD COLUMN publication_source_path varchar(120),
        ADD COLUMN forum_publication_enabled boolean NOT NULL DEFAULT false,
        ADD COLUMN publication_category_mode varchar(32) NOT NULL DEFAULT 'all_except_selected',
        ADD COLUMN publication_category_ids jsonb NOT NULL DEFAULT '[]',
        ADD COLUMN publication_excluded_category_ids jsonb NOT NULL DEFAULT '[]',
        ADD COLUMN publication_tag_mode varchar(32) NOT NULL DEFAULT 'all',
        ADD COLUMN publication_tag_ids jsonb NOT NULL DEFAULT '[]',
        ADD COLUMN publication_excluded_tag_ids jsonb NOT NULL DEFAULT '[]',
        ADD COLUMN publication_include_unlisted boolean NOT NULL DEFAULT false,
        ADD COLUMN platform_catalog jsonb NOT NULL DEFAULT '{}',
        ADD COLUMN platform_catalog_revision varchar(64),
        ADD COLUMN platform_catalog_display_revision varchar(64),
        ADD COLUMN platform_catalog_adapter_id varchar(100),
        ADD COLUMN platform_catalog_adapter_version varchar(100),
        ADD COLUMN platform_catalog_observed_at timestamp,
        ADD COLUMN platform_catalog_refresh_requested_at timestamp,
        ADD COLUMN destination_mapping jsonb NOT NULL DEFAULT '{}',
        ADD COLUMN destination_mapping_revision varchar(64),
        ADD COLUMN destination_mapping_updated_at timestamp,
        ADD COLUMN publication_attention_fingerprint varchar(64),
        ADD COLUMN publication_attention_notified_at timestamp;
      ALTER TABLE discussion_bridge_bridge_records
        ADD COLUMN destination_state varchar(32),
        ADD COLUMN publication_program varchar(32) NOT NULL DEFAULT 'legacy',
        ADD COLUMN acknowledged_source_revision varchar(128),
        ADD COLUMN acknowledged_publication_revision varchar(64),
        ADD COLUMN acknowledged_mapping_revision varchar(64),
        ADD COLUMN acknowledged_destination jsonb NOT NULL DEFAULT '{}',
        ADD COLUMN pending_publication_revision varchar(64),
        ADD COLUMN pending_mapping_revision varchar(64),
        ADD COLUMN pending_destination jsonb NOT NULL DEFAULT '{}',
        ADD COLUMN acknowledged_at timestamp, ADD COLUMN last_delivery_outcome varchar(32),
        ADD COLUMN last_delivery_attempt_at timestamp,
        ADD COLUMN delivery_attempt_count integer NOT NULL DEFAULT 0,
        ADD COLUMN last_delivery_error_code varchar(64),
        ADD COLUMN last_delivery_error_detail varchar(1000),
        ADD COLUMN attempted_publication_revision varchar(64),
        ADD COLUMN attempted_mapping_revision varchar(64),
        ADD COLUMN attempted_destination jsonb NOT NULL DEFAULT '{}';
      CREATE TABLE discussion_bridge_source_url_histories (
        id bigserial PRIMARY KEY, bridge_record_id bigint NOT NULL, content_binding_id bigint NOT NULL,
        verified_by_id bigint NOT NULL, old_canonical_url text NOT NULL, new_canonical_url text NOT NULL,
        old_canonical_url_digest varchar(64) NOT NULL, redirect_status integer NOT NULL,
        verified_at timestamp NOT NULL, created_at timestamp NOT NULL, updated_at timestamp NOT NULL
      );
      CREATE TABLE discussion_bridge_presentation_url_histories
        (LIKE discussion_bridge_source_url_histories INCLUDING ALL);
      CREATE TABLE discussion_bridge_publication_overrides (
        id bigserial PRIMARY KEY, content_connection_id bigint NOT NULL, topic_id bigint NOT NULL,
        set_by_id bigint NOT NULL, decision varchar(16) NOT NULL,
        created_at timestamp NOT NULL, updated_at timestamp NOT NULL
      );
      CREATE TABLE discussion_bridge_publication_work_items (
        id bigserial PRIMARY KEY, content_connection_id bigint NOT NULL, topic_id bigint NOT NULL,
        bridge_record_id bigint, action varchar(32) NOT NULL, state varchar(32) NOT NULL,
        reason varchar(64), source_revision varchar(128), publication_revision varchar(64),
        policy_revision varchar(64), lease_token varchar(64), available_at timestamp, claimed_at timestamp,
        lease_expires_at timestamp, completed_at timestamp, attempt_count integer NOT NULL DEFAULT 0,
        last_error_code varchar(64), last_error_detail varchar(1000),
        created_at timestamp NOT NULL, updated_at timestamp NOT NULL
      );
      CREATE TABLE discussion_bridge_operator_services (
        id bigserial PRIMARY KEY, singleton_key varchar(16) NOT NULL DEFAULT 'current',
        installation_id varchar(36) NOT NULL, enrollment_id varchar(36) NOT NULL,
        enabled boolean NOT NULL DEFAULT false, status varchar(32) NOT NULL DEFAULT 'inactive',
        requested_by_id bigint, requested_at timestamp, disabled_at timestamp,
        notification_state varchar(32) NOT NULL DEFAULT 'not_sent', notification_sent_at timestamp,
        notification_error text, entitlement_id varchar(64), operator_identity_id varchar(100),
        operator_email varchar(254), operator_user_id bigint, identity_version integer NOT NULL DEFAULT 0,
        entitlement_version integer NOT NULL DEFAULT 0, plan_id varchar(100), issued_at timestamp,
        paid_through_at timestamp, grace_expires_at timestamp, entitlement_digest varchar(64),
        entitlement_payload jsonb NOT NULL DEFAULT '{}', created_at timestamp NOT NULL, updated_at timestamp NOT NULL
      );
      CREATE TABLE discussion_bridge_operator_events (
        id bigserial PRIMARY KEY, operator_service_id bigint NOT NULL, actor_user_id bigint,
        topic_id bigint, content_connection_id bigint, bridge_record_id bigint,
        event_type varchar(100) NOT NULL, outcome varchar(32) NOT NULL,
        details jsonb NOT NULL DEFAULT '{}', created_at timestamp NOT NULL
      );
    SQL
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
