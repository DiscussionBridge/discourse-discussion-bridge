# frozen_string_literal: true

require "rails_helper"
require "pg"
require "timeout"

RSpec.describe "R3-F07 URL migration lock ordering" do
  self.use_transactional_tests = false

  before do
    @workers = []
    @connection_ids = []
    @connection_public_ids = []
    @record_ids = []
    @topic_ids = []
    @users = []
  end

  after do
    survivors = []
    @workers.each do |worker|
      worker.kill if worker.alive?
      worker.join(5)
      survivors << worker if worker.alive?
    end
    raise "R3-F07 worker survived example cleanup" if survivors.any?

    cleanup_created_rows
  end

  it "lets proof hold the connection while apply waits without prelocking the record" do
    connection = issue_connection("Apply proof")
    record, active = create_source_record(connection: connection, state: "migration")
    prepared = create_binding(
      connection: connection,
      record: record,
      state: "prepared",
      external_id: "prepared-apply-proof",
      canonical_url: "https://source.example/prepared-apply-proof/",
    )
    proof_holds_connection = Queue.new
    continue_proof = Queue.new
    proof_result = Queue.new
    apply_pid = Queue.new
    apply_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    proof_worker = start_worker(proof_result) do
      DiscussionBridgeContentConnection.transaction do
        locked_connection = DiscussionBridgeContentConnection.lock.find(connection.id)
        proof_holds_connection << true
        continue_proof.pop
        begin
          DiscussionBridge::SourceUrlProof.call(
            connection: locked_connection,
            record: DiscussionBridgeBridgeRecord.find(record.id),
            from_url: active.canonical_url,
            to_url: active.canonical_url,
          )
        rescue DiscussionBridge::AdapterRequestBoundary::Error => error
          error
        end
      end
    end
    wait_for(proof_holds_connection)

    apply_worker = start_worker(apply_result) do
      apply_pid << database_pid
      call_admin_controller(
        :apply_migration,
        id: record.id,
        binding_id: prepared.id,
      )
    end
    wait_for_database_lock(wait_for(apply_pid))
    continue_proof << true
    wait_for(proof_worker)
    wait_for(apply_worker)

    proof_error = proof_result.pop
    expect(proof_error).to be_a(DiscussionBridge::AdapterRequestBoundary::Error)
    expect(proof_error.error_code).to eq("reconciliation_required")
    expect(apply_result.pop.fetch(:json).fetch(:bridge_record).fetch(:state)).to eq("healthy")
    expect(record.reload.state).to eq("healthy")
    expect(record.content_bindings.where(state: "active").sole.id).to eq(prepared.id)
    expect(record.content_bindings.where(state: "historical").sole.id).to eq(active.id)
    expect(record.source_url_histories).to be_empty
  ensure
    continue_proof << true if defined?(continue_proof) && proof_worker&.alive?
  end

  it "lets apply hold connection and record while proof waits and then rejects cleanly" do
    connection = issue_connection("Apply first")
    record, active = create_source_record(connection: connection, state: "migration")
    prepared = create_binding(
      connection: connection,
      record: record,
      state: "prepared",
      external_id: "prepared-apply-first",
      canonical_url: "https://source.example/prepared-apply-first/",
    )
    apply_holds_locks = Queue.new
    continue_apply = Queue.new
    apply_result = Queue.new
    proof_pid = Queue.new
    proof_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    apply_worker = start_worker(apply_result) do
      DiscussionBridgeBridgeRecord.transaction do
        DiscussionBridgeContentConnection.lock.find(connection.id)
        DiscussionBridgeBridgeRecord.lock.find(record.id)
        apply_holds_locks << true
        continue_apply.pop
        call_admin_controller(
          :apply_migration,
          id: record.id,
          binding_id: prepared.id,
        )
      end
    end
    wait_for(apply_holds_locks)

    proof_worker = start_worker(proof_result) do
      proof_pid << database_pid
      begin
        DiscussionBridge::SourceUrlProof.call(
          connection: DiscussionBridgeContentConnection.find(connection.id),
          record: DiscussionBridgeBridgeRecord.find(record.id),
          from_url: active.canonical_url,
          to_url: prepared.canonical_url,
        )
      rescue DiscussionBridge::AdapterRequestBoundary::Error => error
        error
      end
    end
    wait_for_database_lock(wait_for(proof_pid))
    continue_apply << true
    wait_for(apply_worker)
    wait_for(proof_worker)

    expect(apply_result.pop.fetch(:json).fetch(:bridge_record).fetch(:state)).to eq("healthy")
    proof_error = proof_result.pop
    expect(proof_error).to be_a(DiscussionBridge::AdapterRequestBoundary::Error)
    expect(proof_error.error_code).to eq("reconciliation_required")
    expect(record.reload.state).to eq("healthy")
    expect(record.content_bindings.where(state: "active").sole.id).to eq(prepared.id)
    expect(record.content_bindings.where(state: "historical").sole.id).to eq(active.id)
    expect(record.source_url_histories).to be_empty
  ensure
    continue_apply << true if defined?(continue_apply) && apply_worker&.alive?
  end

  it "lets proof hold the connection while prepare waits without prelocking the record" do
    connection = issue_connection("Prepare proof")
    record, active = create_source_record(connection: connection)
    proof_holds_connection = Queue.new
    continue_proof = Queue.new
    proof_result = Queue.new
    prepare_pid = Queue.new
    prepare_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    proof_worker = start_worker(proof_result) do
      DiscussionBridgeContentConnection.transaction do
        locked_connection = DiscussionBridgeContentConnection.lock.find(connection.id)
        proof_holds_connection << true
        continue_proof.pop
        begin
          DiscussionBridge::SourceUrlProof.call(
            connection: locked_connection,
            record: DiscussionBridgeBridgeRecord.find(record.id),
            from_url: active.canonical_url,
            to_url: active.canonical_url,
          )
        rescue DiscussionBridge::AdapterRequestBoundary::Error => error
          error
        end
      end
    end
    wait_for(proof_holds_connection)

    prepare_worker = start_worker(prepare_result) do
      prepare_pid << database_pid
      call_admin_controller(
        :prepare_migration,
        id: record.id,
        migration: {
          content_connection_id: connection.id,
          external_id: "prepared-proof-first",
          canonical_url: "https://source.example/prepared-proof-first/",
        },
      )
    end
    wait_for_database_lock(wait_for(prepare_pid))
    continue_proof << true
    wait_for(proof_worker)
    wait_for(prepare_worker)

    proof_error = proof_result.pop
    expect(proof_error).to be_a(DiscussionBridge::AdapterRequestBoundary::Error)
    expect(proof_error.error_code).to eq("reconciliation_required")
    expect(prepare_result.pop.fetch(:json).fetch(:prepared_binding_id)).to be_present
    expect(record.reload.state).to eq("migration")
    expect(record.content_bindings.where(state: "active").sole.id).to eq(active.id)
    expect(record.content_bindings.where(state: "prepared").count).to eq(1)
  ensure
    continue_proof << true if defined?(continue_proof) && proof_worker&.alive?
  end

  it "lets prepare hold connection and record while proof waits and then rejects cleanly" do
    connection = issue_connection("Prepare first proof")
    record, active = create_source_record(connection: connection)
    prepare_holds_locks = Queue.new
    continue_prepare = Queue.new
    prepare_result = Queue.new
    proof_pid = Queue.new
    proof_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    prepare_worker = start_worker(prepare_result) do
      DiscussionBridgeBridgeRecord.transaction do
        DiscussionBridgeContentConnection.lock.find(connection.id)
        DiscussionBridgeBridgeRecord.lock.find(record.id)
        prepare_holds_locks << true
        continue_prepare.pop
        call_admin_controller(
          :prepare_migration,
          id: record.id,
          migration: {
            content_connection_id: connection.id,
            external_id: "prepared-first-proof",
            canonical_url: "https://source.example/prepared-first-proof/",
          },
        )
      end
    end
    wait_for(prepare_holds_locks)

    proof_worker = start_worker(proof_result) do
      proof_pid << database_pid
      begin
        DiscussionBridge::SourceUrlProof.call(
          connection: DiscussionBridgeContentConnection.find(connection.id),
          record: DiscussionBridgeBridgeRecord.find(record.id),
          from_url: active.canonical_url,
          to_url: active.canonical_url,
        )
      rescue DiscussionBridge::AdapterRequestBoundary::Error => error
        error
      end
    end
    wait_for_database_lock(wait_for(proof_pid))
    continue_prepare << true
    wait_for(prepare_worker)
    wait_for(proof_worker)

    expect(prepare_result.pop.fetch(:json).fetch(:prepared_binding_id)).to be_present
    proof_error = proof_result.pop
    expect(proof_error).to be_a(DiscussionBridge::AdapterRequestBoundary::Error)
    expect(proof_error.error_code).to eq("reconciliation_required")
    expect(record.reload.state).to eq("migration")
    expect(record.content_bindings.where(state: "active").sole.id).to eq(active.id)
    expect(record.content_bindings.where(state: "prepared").count).to eq(1)
  ensure
    continue_prepare << true if defined?(continue_prepare) && prepare_worker&.alive?
  end

  it "serializes an admitted source update before cross-connection preparation" do
    source = issue_connection("Resolver first")
    target = issue_connection("Resolver first target", origin: "https://target.example")
    record, active = create_source_record(connection: source)
    update_entered = Queue.new
    continue_update = Queue.new
    resolver_result = Queue.new
    prepare_pid = Queue.new
    prepare_result = Queue.new
    topic_creator = blocking_topic_creator(record, entered: update_entered, continue: continue_update)
    ActiveRecord::Base.connection_pool.release_connection

    resolver_worker = start_worker(resolver_result) do
      DiscussionBridge::BridgeRecordResolver.call(
        connection: DiscussionBridgeContentConnection.find(source.id),
        request: resolver_request(active, revision_sequence: 2),
        policy: allowed_policy(record),
        topic_creator: topic_creator,
      )
    end
    wait_for(update_entered)

    prepare_worker = start_worker(prepare_result) do
      prepare_pid << database_pid
      call_admin_controller(
        :prepare_migration,
        id: record.id,
        migration: {
          content_connection_id: target.id,
          external_id: "prepared-resolver-first",
          canonical_url: "https://target.example/resolver-first/",
        },
      )
    end
    wait_for_database_lock(wait_for(prepare_pid))
    continue_update << true
    wait_for(resolver_worker)
    wait_for(prepare_worker)

    expect(resolver_result.pop).to have_attributes(outcome: "resolved")
    prepared_id = prepare_result.pop.fetch(:json).fetch(:prepared_binding_id)
    expect(record.reload).to have_attributes(state: "migration", source_revision_sequence: 2)
    expect(record.content_bindings.where(state: "active").sole.id).to eq(active.id)
    expect(record.content_bindings.where(state: "prepared").sole.id).to eq(prepared_id)
  ensure
    continue_update << true if defined?(continue_update) && resolver_worker&.alive?
  end

  it "makes an admitted resolver recheck record state after preparation wins" do
    source = issue_connection("Prepare first")
    target = issue_connection("Prepare first target", origin: "https://target.example")
    record, active = create_source_record(connection: source)
    prepare_holds_locks = Queue.new
    continue_prepare = Queue.new
    prepare_result = Queue.new
    resolver_pid = Queue.new
    resolver_result = Queue.new
    update_entered = Queue.new
    topic_creator = blocking_topic_creator(record, entered: update_entered, continue: Queue.new)
    ActiveRecord::Base.connection_pool.release_connection

    prepare_worker = start_worker(prepare_result) do
      DiscussionBridgeBridgeRecord.transaction do
        DiscussionBridgeContentConnection.lock.find(target.id)
        DiscussionBridgeBridgeRecord.lock.find(record.id)
        prepare_holds_locks << true
        continue_prepare.pop
        call_admin_controller(
          :prepare_migration,
          id: record.id,
          migration: {
            content_connection_id: target.id,
            external_id: "prepared-wins",
            canonical_url: "https://target.example/prepared-wins/",
          },
        )
      end
    end
    wait_for(prepare_holds_locks)

    resolver_worker = start_worker(resolver_result) do
      resolver_pid << database_pid
      DiscussionBridge::BridgeRecordResolver.call(
        connection: DiscussionBridgeContentConnection.find(source.id),
        request: resolver_request(active, revision_sequence: 2),
        policy: allowed_policy(record),
        topic_creator: topic_creator,
      )
    end
    wait_for_database_lock(wait_for(resolver_pid))
    continue_prepare << true
    wait_for(prepare_worker)
    wait_for(resolver_worker)

    expect(prepare_result.pop.fetch(:json).fetch(:prepared_binding_id)).to be_present
    expect(resolver_result.pop).to have_attributes(
      outcome: "reconciliation_required",
      reason: "bridge_record_unavailable",
    )
    expect(update_entered).to be_empty
    expect(record.reload).to have_attributes(state: "migration", source_revision_sequence: 1)
    expect(record.content_bindings.where(state: "active").sole.id).to eq(active.id)
    expect(record.content_bindings.where(state: "prepared").count).to eq(1)
  ensure
    continue_prepare << true if defined?(continue_prepare) && prepare_worker&.alive?
  end

  it "rejects an apply whose prepared binding identity changes after discovery" do
    discovered_connection = issue_connection("Apply discovery")
    replacement_connection = issue_connection("Apply discovery replacement")
    record, active = create_source_record(connection: discovered_connection, state: "migration")
    prepared = create_binding(
      connection: discovered_connection,
      record: record,
      state: "prepared",
      external_id: "prepared-discovery",
      canonical_url: "https://source.example/prepared-discovery/",
    )
    connection_locked = Queue.new
    continue_holder = Queue.new
    holder_result = Queue.new
    apply_pid = Queue.new
    apply_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    holder = start_worker(holder_result) do
      DiscussionBridgeContentConnection.transaction do
        DiscussionBridgeContentConnection.lock.find(discovered_connection.id)
        connection_locked << true
        continue_holder.pop
      end
      :released
    end
    wait_for(connection_locked)

    apply_worker = start_worker(apply_result) do
      apply_pid << database_pid
      call_admin_controller(
        :apply_migration,
        id: record.id,
        binding_id: prepared.id,
      )
    end
    wait_for_database_lock(wait_for(apply_pid))
    database = PG.connect(dbname: ActiveRecord::Base.connection_db_config.database)
    database.exec("SET lock_timeout = '5s'; SET statement_timeout = '6s'")
    Timeout.timeout(10) do
      database.exec_params(
        "UPDATE discussion_bridge_content_bindings SET content_connection_id = $1 WHERE id = $2",
        [replacement_connection.id, prepared.id],
      )
    end
    continue_holder << true
    wait_for(holder)
    wait_for(apply_worker)

    expect(holder_result.pop).to eq(:released)
    response = apply_result.pop
    expect(response.fetch(:status)).to eq(:unprocessable_entity)
    expect(record.reload.state).to eq("migration")
    expect(active.reload.state).to eq("active")
    expect(prepared.reload).to have_attributes(
      state: "prepared",
      content_connection_id: replacement_connection.id,
    )
    expect(record.content_bindings.count).to eq(2)
  ensure
    database&.close
    continue_holder << true if defined?(continue_holder) && holder&.alive?
  end

  it "serializes identical verified URL migrations into one history transition" do
    connection = issue_connection("Identical URL")
    record, binding = create_source_record(connection: connection)
    old_url = binding.canonical_url
    new_url = "https://source.example/articles/#{record.id}-current/"
    create_topic_embed(record, old_url)
    verification_entered = Queue.new
    continue_verification = Queue.new
    first_result = Queue.new
    second_result = Queue.new
    verifier = lambda do |**|
      verification_entered << true
      continue_verification.pop
      308
    end
    ActiveRecord::Base.connection_pool.release_connection

    workers = [first_result, second_result].map do |result|
      start_worker(result) do
        migrate_url(
          record: record,
          binding: binding,
          old_url: old_url,
          new_url: new_url,
          verifier: verifier,
        )
      end
    end
    2.times { wait_for(verification_entered) }
    2.times { continue_verification << true }
    workers.each { |worker| wait_for(worker) }

    results = [first_result.pop, second_result.pop]
    expect(results).to all(be_a(DiscussionBridge::VerifiedUrlMigrator::Result))
    expect(results.map(&:outcome)).to contain_exactly("migrated", "already_current")
    expect(record.source_url_histories.count).to eq(1)
    expect(binding.reload.canonical_url).to eq(new_url)
    expect(TopicEmbed.find_by!(topic_id: record.topic_id).embed_url).to eq(
      TopicEmbed.normalize_url(new_url),
    )
  ensure
    2.times { continue_verification << true } if defined?(continue_verification)
  end

  it "allows only one of two competing URL successors to commit" do
    connection = issue_connection("Competing URL")
    record, binding = create_source_record(connection: connection)
    old_url = binding.canonical_url
    successors = %w[first second].map do |suffix|
      "https://source.example/articles/#{record.id}-#{suffix}/"
    end
    create_topic_embed(record, old_url)
    verification_entered = Queue.new
    continue_verification = Queue.new
    result_queues = [Queue.new, Queue.new]
    verifier = lambda do |**|
      verification_entered << true
      continue_verification.pop
      308
    end
    ActiveRecord::Base.connection_pool.release_connection

    workers = successors.zip(result_queues).map do |new_url, result|
      start_worker(result) do
        migrate_url(
          record: record,
          binding: binding,
          old_url: old_url,
          new_url: new_url,
          verifier: verifier,
        )
      end
    end
    2.times { wait_for(verification_entered) }
    2.times { continue_verification << true }
    workers.each { |worker| wait_for(worker) }

    results = result_queues.map(&:pop)
    winner = results.find { |result| result.is_a?(DiscussionBridge::VerifiedUrlMigrator::Result) }
    loser = results.find { |result| result.is_a?(ArgumentError) }
    expect(winner).to have_attributes(outcome: "migrated")
    expect(loser.message).to eq("retired URL does not match the active binding")
    expect(record.source_url_histories.count).to eq(1)
    expect(successors).to include(binding.reload.canonical_url)
    expect(TopicEmbed.find_by!(topic_id: record.topic_id).embed_url).to eq(
      TopicEmbed.normalize_url(binding.canonical_url),
    )
  ensure
    2.times { continue_verification << true } if defined?(continue_verification)
  end

  it "rechecks connection scope after redirect verification without partial mutation" do
    connection = issue_connection("Scope recheck")
    record, binding = create_source_record(connection: connection)
    old_url = binding.canonical_url
    new_url = "https://source.example/articles/#{record.id}-scope/"
    embed = create_topic_embed(record, old_url)
    verification_entered = Queue.new
    continue_verification = Queue.new
    migration_result = Queue.new
    verifier = lambda do |**|
      verification_entered << true
      continue_verification.pop
      308
    end
    ActiveRecord::Base.connection_pool.release_connection

    worker = start_worker(migration_result) do
      migrate_url(
        record: record,
        binding: binding,
        old_url: old_url,
        new_url: new_url,
        verifier: verifier,
      )
    end
    wait_for(verification_entered)
    connection.update!(allowed_lanes: ["news"])
    continue_verification << true
    wait_for(worker)

    error = migration_result.pop
    expect(error).to be_a(ArgumentError)
    expect(error.message).to eq("Content Connection is unavailable")
    expect(binding.reload.canonical_url).to eq(old_url)
    expect(embed.reload.embed_url).to eq(TopicEmbed.normalize_url(old_url))
    expect(record.source_url_histories).to be_empty
  ensure
    continue_verification << true if defined?(continue_verification) && worker&.alive?
  end

  it "rolls back history and Core embed mutation when the binding update fails" do
    connection = issue_connection("URL rollback")
    record, binding = create_source_record(connection: connection)
    old_url = binding.canonical_url
    new_url = "https://source.example/articles/#{record.id}-rollback/"
    embed = create_topic_embed(record, old_url)
    failure = proc do
      if id == binding.id && will_save_change_to_canonical_url?
        raise "injected binding update failure"
      end
    end
    DiscussionBridgeContentBinding.set_callback(:update, :before, failure)

    expect do
      migrate_url(
        record: record,
        binding: binding,
        old_url: old_url,
        new_url: new_url,
        verifier: ->(**) { 308 },
      )
    end.to raise_error(RuntimeError, "injected binding update failure")

    expect(binding.reload.canonical_url).to eq(old_url)
    expect(embed.reload.embed_url).to eq(TopicEmbed.normalize_url(old_url))
    expect(record.source_url_histories).to be_empty
  ensure
    DiscussionBridgeContentBinding.skip_callback(:update, :before, failure) if defined?(failure)
  end

  it "rolls back retired and prepared binding changes when apply fails" do
    connection = issue_connection("Apply rollback")
    record, active = create_source_record(connection: connection, state: "migration")
    prepared = create_binding(
      connection: connection,
      record: record,
      state: "prepared",
      external_id: "prepared-rollback",
      canonical_url: "https://source.example/prepared-rollback/",
    )
    resource_id = record.resource_id
    topic_id = record.topic_id
    failure = proc do
      if id == prepared.id && state == "active" && will_save_change_to_state?
        raise "injected apply failure"
      end
    end
    DiscussionBridgeContentBinding.set_callback(:update, :before, failure)

    expect do
      call_admin_controller(
        :apply_migration,
        id: record.id,
        binding_id: prepared.id,
      )
    end.to raise_error(RuntimeError, "injected apply failure")

    expect(record.reload).to have_attributes(
      resource_id: resource_id,
      topic_id: topic_id,
      state: "migration",
    )
    expect(active.reload.state).to eq("active")
    expect(prepared.reload.state).to eq("prepared")
    expect(record.content_bindings.count).to eq(2)
  ensure
    DiscussionBridgeContentBinding.skip_callback(:update, :before, failure) if defined?(failure)
  end

  private

  def issue_connection(name, origin: "https://source.example")
    connection, = DiscussionBridgeContentConnection.issue!(
      name: "#{name} #{SecureRandom.hex(4)}",
      platform: "wordpress",
      allowed_origins: [origin],
      allowed_directions: ["to_discourse"],
      allowed_lanes: ["articles"],
    )
    @connection_ids << connection.id
    @connection_public_ids << connection.public_id
    connection
  end

  def create_source_record(connection:, state: "healthy")
    identity = SecureRandom.hex(6)
    user = Fabricate(
      :admin,
      username: "r3f07#{identity}",
      email: "r3f07#{identity}@example.com",
    )
    @users << user
    topic = Fabricate(:topic, user: user, title: "R3 F07 topic #{identity}")
    Fabricate(:post, topic: topic, user: user, post_number: 1)
    @topic_ids << topic.id
    content = "<p>revision one</p>"
    record = DiscussionBridgeBridgeRecord.create!(
      resource_id: SecureRandom.uuid,
      direction: "to_discourse",
      state: state,
      title: "R3-F07 source",
      topic: topic,
      effective_actor: user,
      lane: "articles",
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      source_authors: [],
      presentation_mode: "interactive",
      source_revision: "source:revision:1",
      source_revision_sequence: 1,
      source_created_at: Time.zone.parse("2026-09-01T00:00:00Z"),
      source_updated_at: Time.zone.parse("2026-09-01T01:00:00Z"),
      source_created_at_wire: "2026-09-01T00:00:00Z",
      source_updated_at_wire: "2026-09-01T01:00:00Z",
      content_disposition: "complete",
      source_content_bytes: content.bytesize,
      source_content_sha256: Digest::SHA256.hexdigest(content),
      delivered_content_sha256: Digest::SHA256.hexdigest(content),
    )
    @record_ids << record.id
    binding = create_binding(
      connection: connection,
      record: record,
      state: "active",
      external_id: "source-#{record.id}",
      canonical_url: "https://source.example/articles/#{record.id}/",
    )
    [record, binding]
  end

  def create_binding(connection:, record:, state:, external_id:, canonical_url:)
    DiscussionBridgeContentBinding.create!(
      bridge_record: record,
      content_connection: connection,
      role: "source",
      state: state,
      external_id: external_id,
      canonical_url: canonical_url,
      identity_digest: Digest::SHA256.hexdigest("#{connection.public_id}\n#{external_id}"),
      canonical_url_digest: Digest::SHA256.hexdigest("#{connection.public_id}\n#{canonical_url}"),
      presentation_mode: "interactive",
      content_disposition: "complete",
    )
  end

  def resolver_request(binding, revision_sequence:)
    content = "<p>revision #{revision_sequence}</p>"
    {
      direction: "to_discourse",
      external_id: binding.external_id,
      canonical_url: binding.canonical_url,
      title: "R3-F07 source revision #{revision_sequence}",
      content_html: content,
      presentation_mode: "interactive",
      source_revision: "source:revision:#{revision_sequence}",
      source_revision_sequence: revision_sequence,
      source_created_at: Time.zone.parse("2026-09-01T00:00:00Z"),
      source_updated_at: Time.zone.parse("2026-09-01T0#{revision_sequence}:00:00Z"),
      source_created_at_wire: "2026-09-01T00:00:00Z",
      source_updated_at_wire: "2026-09-01T0#{revision_sequence}:00:00Z",
      content_disposition: "complete",
      source_content_bytes: content.bytesize,
      source_content_sha256: Digest::SHA256.hexdigest(content),
      visibility: "unlisted",
      lane: "articles",
      source_authors: [],
      correlation_id: "r3-f07-#{revision_sequence}",
    }
  end

  def allowed_policy(record)
    DiscussionBridge::PolicyEvaluator::Result.new(
      allowed: true,
      reason: "forum_policy_applied",
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      operating_actor_id: record.effective_actor_id,
      effective_actor_id: record.effective_actor_id,
      effective_category_id: record.topic.category_id,
      effective_tags: [],
      compatibility_mode: false,
    )
  end

  def blocking_topic_creator(record, entered:, continue:)
    Object.new.tap do |creator|
      creator.define_singleton_method(:update) do |**|
        entered << true
        continue.pop
        record.topic.first_post.reload
      end
    end
  end

  def create_topic_embed(record, url)
    TopicEmbed.create!(
      topic_id: record.topic_id,
      post_id: record.topic.first_post.id,
      embed_url: TopicEmbed.normalize_url(url),
    )
  end

  def migrate_url(record:, binding:, old_url:, new_url:, verifier:)
    DiscussionBridge::VerifiedUrlMigrator.call(
      user: User.find(record.effective_actor_id),
      resource_id: record.resource_id,
      role: "source",
      old_url: old_url,
      new_url: new_url,
      external_id: binding.external_id,
      native_identity_confirmed: true,
      verifier: verifier,
    )
  end

  def call_admin_controller(action, parameters)
    controller = DiscussionBridge::AdminBridgeRecordsController.new
    supplied = ActionController::Parameters.new(parameters)
    rendered = nil
    controller.define_singleton_method(:params) { supplied }
    controller.define_singleton_method(:render) do |*arguments, **options|
      rendered = options.merge(arguments: arguments)
    end
    controller.public_send(action)
    rendered
  end

  def start_worker(result, &block)
    Thread.new do
      begin
        ActiveRecord::Base.connection_pool.with_connection do
          result << block.call
        end
      rescue StandardError => error
        result << error
      end
    end.tap do |worker|
      worker.report_on_exception = false
      @workers << worker
    end
  end

  def database_pid
    ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()").to_i
  end

  def wait_for(target)
    Timeout.timeout(15) do
      target.is_a?(Thread) ? target.join : target.pop
    end
  end

  def wait_for_database_lock(backend_pid)
    observer = PG.connect(dbname: ActiveRecord::Base.connection_db_config.database)
    Timeout.timeout(15) do
      loop do
        result = observer.exec_params(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
          [Integer(backend_pid)],
        )
        return if result.ntuples == 1 && result.getvalue(0, 0) == "Lock"

        sleep 0.01
      end
    end
  ensure
    observer&.close
  end

  def cleanup_created_rows
    DiscussionBridgeSourceUrlHistory.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgePresentationUrlHistory.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgePublicationWork.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgeContentBinding.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgeAuditEvent.where(connection_id: @connection_public_ids).delete_all
    DiscussionBridgeBridgeRecord.where(id: @record_ids).delete_all
    TopicEmbed.where(topic_id: @topic_ids).delete_all
    Post.where(topic_id: @topic_ids).delete_all
    Topic.where(id: @topic_ids).delete_all
    DiscussionBridgeContentConnection.where(id: @connection_ids).delete_all
    @users.reverse_each { |user| user.destroy! if User.exists?(user.id) }
  end
end
