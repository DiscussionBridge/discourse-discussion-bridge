# frozen_string_literal: true

schema_name = ENV.fetch("DISCUSSION_BRIDGE_R3_F02_SCHEMA")
phase = ENV.fetch("DISCUSSION_BRIDGE_R3_F02_PHASE")
raise "invalid restart schema" unless /\Adb_r3_f02_restart_[a-f0-9]{12}\z/.match?(schema_name)

connection = ActiveRecord::Base.connection
plugin_root = File.expand_path("../../..", __dir__)
migration_path = File.join(plugin_root, "db/migrate")

policy = lambda do |profile, identifier, container|
  {
    "destination_policy_id" => identifier,
    "profile" => profile,
    "presentation_mode" => "interactive",
    "container_mapping" => {
      "source" => "discourse:category:articles",
      "destination" => container,
    },
    "taxonomy_mapping" => { "mode" => "mapped_only" },
    "author_mapping" => { "mode" => "source_attribution" },
    "native_limit_policy" => {
      "maximum_bytes" => 49_152,
      "overflow_behavior" => "excerpt_with_read_more",
    },
    "catalog_revision" => "catalog:#{profile}:restart:1",
  }
end

policy_a_dynamic = policy.call("wordpress", "destination:wordpress:articles:restart", "site:articles")
policy_b_dynamic = policy.call("wordpress", "destination:wordpress:archive:restart", "site:archive")
policy_a_static = policy.call("astro", "destination:astro:articles:restart", "site:articles")
policy_b_static = policy.call("astro", "destination:astro:archive:restart", "site:archive")

reset_models = lambda do
  [
    DiscussionBridgeBridgeRecord,
    DiscussionBridgeContentBinding,
    DiscussionBridgeContentConnection,
    DiscussionBridgePublicationAcknowledgement,
    DiscussionBridgePublicationWork,
    DiscussionBridgeSourceRevocation,
  ].each(&:reset_column_information)
end

claim_one = lambda do |content_connection, correlation|
  DiscussionBridge::PublicationWorkRegistry.claim(
    connection: content_connection,
    worker_id: "r3-f02-restart-worker",
    maximum_items: 1,
    requested_lease_seconds: 60,
    correlation_id: correlation,
  ).sole
end

acknowledgement = lambda do |claimed, record, binding, correlation, revision, stage: "synchronized",
                            stage_token: nil, deployment_state: "not_required",
                            verification_state: "not_required", synchronized_at: nil, **extra|
  {
    lease_token: claimed.fetch(:lease_token),
    resource_id: record.resource_id,
    source_revision: claimed.fetch(:source_revision),
    source_revision_sequence: claimed.fetch(:source_revision_sequence),
    policy_revision: claimed.fetch(:policy_revision),
    destination_policy_id: claimed.fetch(:destination_policy_id),
    action: claimed.fetch(:action),
    stage: stage,
    stage_token: stage_token || claimed.fetch(:stage_token),
    destination_binding: {
      binding_id: binding.binding_id,
      external_id: binding.external_id,
      canonical_url: binding.canonical_url,
      publication_revision: revision,
      content_disposition: "complete",
    },
    synchronized_at: synchronized_at || Time.zone.now.iso8601(6),
    deployment_state: deployment_state,
    verification_state: verification_state,
    correlation_id: correlation,
  }.merge(extra)
end

fail_work = lambda do |content_connection, claimed, correlation, code|
  DiscussionBridge::PublicationWorkRegistry.fail(
    connection: content_connection,
    work_id: claimed.fetch(:work_id),
    payload: {
      lease_token: claimed.fetch(:lease_token),
      error_code: code,
      error_detail: "R3-F02 restart regression injected failure.",
      failed_at: Time.zone.now.iso8601(6),
      correlation_id: correlation,
    },
  )
end

create_scenario = lambda do |name, platform, current_policy, removed_policy, topic_id, sequence_base, static|
  content_connection, = DiscussionBridgeContentConnection.issue!(
    name: name,
    platform: platform,
    allowed_origins: ["https://source.example"],
    allowed_directions: ["from_discourse"],
    allowed_lanes: ["articles"],
    destination_policies: [current_policy],
    catalog_required: true,
    policy_revision: "policy:#{platform}:restart:current",
  )
  record = DiscussionBridgeBridgeRecord.create!(
    resource_id: SecureRandom.uuid,
    direction: "from_discourse",
    state: "healthy",
    title: "#{name} source",
    topic_id: topic_id,
    lane: "articles",
    source_revision: "revision:#{sequence_base + 1}",
    source_revision_sequence: sequence_base + 1,
    source_updated_at: Time.zone.now,
  )
  binding = record.content_bindings.create!(
    content_connection: content_connection,
    role: "presentation",
    state: "active",
    external_id: "restart-#{platform}",
    canonical_url: "https://source.example/restart-#{platform}",
    identity_digest: Digest::SHA256.hexdigest("identity-#{platform}"),
    canonical_url_digest: Digest::SHA256.hexdigest("url-#{platform}"),
    presentation_mode: "interactive",
    content_disposition: "complete",
    deployment_state: "not_required",
    verification_state: "not_required",
  )
  revocation = DiscussionBridgeSourceRevocation.create!(
    bridge_record: record,
    content_connection: content_connection,
    revocation_id: "dbr_#{SecureRandom.hex(16)}",
    source_revision: "revocation:#{record.resource_id}:#{sequence_base + 2}",
    source_revision_sequence: sequence_base + 2,
    reason: "policy_removed",
    effective_at: Time.zone.now,
    restored_at: Time.zone.now,
    restorable: true,
    affected_binding_ids: [binding.binding_id],
    policy_revision: "policy:#{platform}:restart:removed",
  )
  common = {
    bridge_record: record,
    content_binding: binding,
    state: "available",
    catalog_revision: removed_policy.fetch("catalog_revision"),
    presentation_mode: "interactive",
    resolved_taxonomy: [],
    resolved_author: { "mode" => "source_attribution", "destination_id" => nil },
    native_limit_policy: removed_policy.fetch("native_limit_policy"),
    static_deployment: static,
  }
  cleanup = content_connection.publication_works.create!(
    **common,
    source_revocation_record: revocation,
    work_id: "dbw_#{platform == "astro" ? "a" : "c"}#{"1" * 31}",
    action: "unpublish",
    source_revision: revocation.source_revision,
    source_revision_sequence: revocation.source_revision_sequence,
    policy_revision: revocation.policy_revision,
    destination_policy_id: removed_policy.fetch("destination_policy_id"),
    resolved_container: {
      "id" => removed_policy.dig("container_mapping", "destination"),
      "kind" => "post_type",
    },
  )
  continuation = content_connection.publication_works.create!(
    **common,
    source_revocation_record: nil,
    work_id: "dbw_#{platform == "astro" ? "b" : "d"}#{"2" * 31}",
    action: "restore",
    source_revision: "revision:#{sequence_base + 3}",
    source_revision_sequence: sequence_base + 3,
    policy_revision: content_connection.policy_revision,
    destination_policy_id: current_policy.fetch("destination_policy_id"),
    catalog_revision: current_policy.fetch("catalog_revision"),
    resolved_container: {
      "id" => current_policy.dig("container_mapping", "destination"),
      "kind" => "post_type",
    },
  )
  [content_connection, record, binding, cleanup, continuation]
end

assert_static_b_projection = lambda do |binding|
  binding.reload
  raise "static B revision changed" unless binding.publication_revision == "astro:shared:restart-revision"
  raise "static B deployment changed" unless binding.deployment_state == "deployed"
  raise "static B verification changed" unless binding.verification_state == "verified"
  raise "static B deployed timestamp changed" unless binding.deployed_at_wire == "2026-09-30T20:00:01.000000Z"
  raise "static B verification timestamp changed" unless
    binding.publicly_verified_at_wire == "2026-09-30T20:00:02.000000Z"
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
      INSERT INTO topics (id) VALUES (1), (2);
    SQL
    ActiveRecord::MigrationContext.new(migration_path).migrate
    connection.execute("CREATE TABLE r3_f02_restart_receipts (key varchar PRIMARY KEY, value text NOT NULL)")
    reset_models.call

    dynamic_connection, dynamic_record, dynamic_binding, dynamic_a, = create_scenario.call(
      "R3-F02 dynamic restart",
      "wordpress",
      policy_b_dynamic,
      policy_a_dynamic,
      1,
      0,
      false,
    )
    dynamic_claim = claim_one.call(dynamic_connection, "restart-dynamic-prepare-a")
    raise "dynamic A was not claimed" unless dynamic_claim.fetch(:work_id) == dynamic_a.work_id
    blocked = DiscussionBridge::PublicationWorkRegistry.claim(
      connection: dynamic_connection,
      worker_id: "blocked-dynamic-worker",
      maximum_items: 1,
      requested_lease_seconds: 60,
      correlation_id: "restart-dynamic-prepare-blocked",
    )
    raise "dynamic B bypassed active A" unless blocked.empty?
    connection.execute <<~SQL
      INSERT INTO r3_f02_restart_receipts (key, value)
      VALUES ('dynamic_original_lease_digest', #{connection.quote(dynamic_a.reload.lease_token_digest)});
    SQL
    dynamic_a.update_columns(lease_expires_at: 1.second.ago)

    static_connection, static_record, static_binding, static_a, static_b = create_scenario.call(
      "R3-F02 static restart",
      "astro",
      policy_b_static,
      policy_a_static,
      2,
      10,
      true,
    )
    static_claim_a = claim_one.call(static_connection, "restart-static-prepare-a")
    synchronized_at = "2026-09-30T20:00:00.000000Z"
    DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: static_connection,
      work_id: static_a.work_id,
      payload: acknowledgement.call(
        static_claim_a,
        static_record,
        static_binding,
        "restart-static-a-synchronized",
        "astro:shared:restart-revision",
        deployment_state: "pending",
        verification_state: "pending",
        synchronized_at: synchronized_at,
      ),
    )
    fail_work.call(static_connection, static_claim_a, "restart-static-a-deploy-failure", "deploy_failed")
    static_claim_b = claim_one.call(static_connection, "restart-static-prepare-b")
    raise "static B was not claimed" unless static_claim_b.fetch(:work_id) == static_b.work_id
    synchronized_b = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: static_connection,
      work_id: static_b.work_id,
      payload: acknowledgement.call(
        static_claim_b,
        static_record,
        static_binding,
        "restart-static-b-synchronized",
        "astro:shared:restart-revision",
        deployment_state: "pending",
        verification_state: "pending",
        synchronized_at: synchronized_at,
      ),
    )
    deployed_b = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: static_connection,
      work_id: static_b.work_id,
      payload: acknowledgement.call(
        static_claim_b,
        static_record,
        static_binding,
        "restart-static-b-deployed",
        "astro:shared:restart-revision",
        stage: "deployed",
        stage_token: synchronized_b.fetch(:next_stage_token),
        deployment_state: "deployed",
        verification_state: "pending",
        synchronized_at: synchronized_at,
        deployed_at: "2026-09-30T20:00:01.000000Z",
      ),
    )
    DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: static_connection,
      work_id: static_b.work_id,
      payload: acknowledgement.call(
        static_claim_b,
        static_record,
        static_binding,
        "restart-static-b-verified",
        "astro:shared:restart-revision",
        stage: "verified",
        stage_token: deployed_b.fetch(:next_stage_token),
        deployment_state: "deployed",
        verification_state: "verified",
        synchronized_at: synchronized_at,
        deployed_at: "2026-09-30T20:00:01.000000Z",
        publicly_verified_at: "2026-09-30T20:00:02.000000Z",
      ),
    )
    assert_static_b_projection.call(static_binding)
    static_a.update_columns(next_retry_at: 1.second.ago)
    puts "R3-F02 prepare complete pid=#{Process.pid}"
  when "resume"
    connection.schema_search_path = schema_name
    connection.schema_cache.clear!
    reset_models.call

    dynamic_connection = DiscussionBridgeContentConnection.find_by!(name: "R3-F02 dynamic restart")
    dynamic_record = dynamic_connection.publication_works.first.bridge_record
    dynamic_binding = dynamic_record.content_bindings.find_by!(content_connection_id: dynamic_connection.id)
    dynamic_a = dynamic_connection.publication_works.find_by!(action: "unpublish")
    dynamic_b = dynamic_connection.publication_works.find_by!(action: "restore")
    original_digest = connection.select_value(
      "SELECT value FROM r3_f02_restart_receipts WHERE key = 'dynamic_original_lease_digest'",
    )
    dynamic_claim = claim_one.call(dynamic_connection, "restart-dynamic-resume-a")
    raise "dynamic A was discarded after restart" unless dynamic_claim.fetch(:work_id) == dynamic_a.work_id
    raise "dynamic lease credential did not rotate" if dynamic_a.reload.lease_token_digest == original_digest
    blocked = DiscussionBridge::PublicationWorkRegistry.claim(
      connection: dynamic_connection,
      worker_id: "blocked-dynamic-worker-2",
      maximum_items: 1,
      requested_lease_seconds: 60,
      correlation_id: "restart-dynamic-resume-blocked",
    )
    raise "dynamic B bypassed reclaimed A" unless blocked.empty?
    fail_work.call(dynamic_connection, dynamic_claim, "restart-dynamic-a-failure", "destination_unavailable")
    dynamic_claim_b = claim_one.call(dynamic_connection, "restart-dynamic-resume-b")
    raise "dynamic B was not independently claimable" unless dynamic_claim_b.fetch(:work_id) == dynamic_b.work_id
    DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: dynamic_connection,
      work_id: dynamic_b.work_id,
      payload: acknowledgement.call(
        dynamic_claim_b,
        dynamic_record,
        dynamic_binding,
        "restart-dynamic-b-complete",
        "wordpress:archive:restart:PB",
      ),
    )
    dynamic_a.update_columns(next_retry_at: 1.second.ago)

    static_connection = DiscussionBridgeContentConnection.find_by!(name: "R3-F02 static restart")
    static_a = static_connection.publication_works.find_by!(action: "unpublish")
    static_record = static_a.bridge_record
    static_binding = static_a.content_binding
    static_claim = claim_one.call(static_connection, "restart-static-resume-a")
    raise "static A did not resume deployment" unless
      static_claim.fetch(:work_id) == static_a.work_id && static_a.reload.state == "awaiting_deployment"
    synchronized_at = static_a.acknowledgements.find_by!(stage: "synchronized").request_payload.fetch("synchronized_at")
    DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: static_connection,
      work_id: static_a.work_id,
      payload: acknowledgement.call(
        static_claim,
        static_record,
        static_binding,
        "restart-static-a-deployed",
        "astro:shared:restart-revision",
        stage: "deployed",
        deployment_state: "deployed",
        verification_state: "pending",
        synchronized_at: synchronized_at,
        deployed_at: "2026-09-30T20:05:01.000000Z",
      ),
    )
    assert_static_b_projection.call(static_binding)
    fail_work.call(static_connection, static_claim, "restart-static-a-verification-failure", "public_verification_failed")
    assert_static_b_projection.call(static_binding)
    static_a.update_columns(next_retry_at: 1.second.ago)
    puts "R3-F02 resume complete pid=#{Process.pid}"
  when "verify"
    connection.schema_search_path = schema_name
    connection.schema_cache.clear!
    reset_models.call

    dynamic_connection = DiscussionBridgeContentConnection.find_by!(name: "R3-F02 dynamic restart")
    dynamic_a = dynamic_connection.publication_works.find_by!(action: "unpublish")
    dynamic_b = dynamic_connection.publication_works.find_by!(action: "restore")
    dynamic_record = dynamic_a.bridge_record
    dynamic_binding = dynamic_a.content_binding
    dynamic_claim = claim_one.call(dynamic_connection, "restart-dynamic-verify-a")
    dynamic_payload = acknowledgement.call(
      dynamic_claim,
      dynamic_record,
      dynamic_binding,
      "restart-dynamic-a-complete",
      "wordpress:articles:restart:PA",
    )
    first = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: dynamic_connection,
      work_id: dynamic_a.work_id,
      payload: dynamic_payload,
    )
    replay = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: dynamic_connection,
      work_id: dynamic_a.work_id,
      payload: dynamic_payload,
    )
    raise "dynamic acknowledgement replay changed" unless replay == first
    raise "dynamic cleanup was duplicated" unless dynamic_connection.publication_works.where(action: "unpublish").count == 1
    raise "dynamic terminal states were not retained" unless
      dynamic_a.reload.state == "acknowledged" && dynamic_b.reload.state == "acknowledged"

    static_connection = DiscussionBridgeContentConnection.find_by!(name: "R3-F02 static restart")
    static_a = static_connection.publication_works.find_by!(action: "unpublish")
    static_record = static_a.bridge_record
    static_binding = static_a.content_binding
    static_claim = claim_one.call(static_connection, "restart-static-verify-a")
    synchronized = static_a.acknowledgements.find_by!(stage: "synchronized").request_payload
    deployed = static_a.acknowledgements.find_by!(stage: "deployed").request_payload
    static_payload = acknowledgement.call(
      static_claim,
      static_record,
      static_binding,
      "restart-static-a-verified",
      "astro:shared:restart-revision",
      stage: "verified",
      deployment_state: "deployed",
      verification_state: "verified",
      synchronized_at: synchronized.fetch("synchronized_at"),
      deployed_at: deployed.fetch("deployed_at"),
      publicly_verified_at: "2026-09-30T20:10:02.000000Z",
    )
    first = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: static_connection,
      work_id: static_a.work_id,
      payload: static_payload,
    )
    replay = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: static_connection,
      work_id: static_a.work_id,
      payload: static_payload,
    )
    raise "static acknowledgement replay changed" unless replay == first
    raise "static A did not reach terminal state" unless static_a.reload.state == "acknowledged"
    assert_static_b_projection.call(static_binding)
    puts "R3-F02 verify complete pid=#{Process.pid}"
  when "cleanup"
    connection.schema_search_path = original_search_path
    connection.execute("DROP SCHEMA IF EXISTS #{schema_name} CASCADE")
    puts "R3-F02 cleanup complete pid=#{Process.pid}"
  else
    raise "unknown restart phase"
  end
ensure
  connection.schema_search_path = original_search_path
  connection.schema_cache.clear!
end
