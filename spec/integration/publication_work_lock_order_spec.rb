# frozen_string_literal: true

require "rails_helper"
require "pg"
require "timeout"

RSpec.describe "R3-F15 publication work lock order" do
  self.use_transactional_tests = false
  include ActiveSupport::Testing::TimeHelpers

  before do
    @workers = []
    @connection_ids = []
    @connection_public_ids = []
    @catalog_ids = []
    @record_ids = []
    @topic_ids = []
    @users = []
    @site_settings = {
      discussion_bridge_enabled: SiteSetting.discussion_bridge_enabled,
      discussion_bridge_endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
      discussion_bridge_service_username: SiteSetting.discussion_bridge_service_username,
      discussion_bridge_effective_tags: SiteSetting.discussion_bridge_effective_tags,
      discussion_bridge_lane_policies: SiteSetting.discussion_bridge_lane_policies,
    }
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
  end

  after do
    survivors = []
    @workers.each do |worker|
      worker.kill if worker.alive?
      worker.join(5)
      survivors << worker if worker.alive?
    end
    raise "R3-F15 worker survived example cleanup" if survivors.any?

    travel_back
    cleanup_created_rows
    @site_settings.each { |name, value| SiteSetting.public_send("#{name}=", value) }
  end

  it "lets generation supersede expired static work before a late deployment acknowledgement" do
    source = prepare_expired_static_work
    update_source_post!(source.fetch(:post))
    generation_holds_locks = Queue.new
    continue_generation = Queue.new
    generation_result = Queue.new
    acknowledgement_pid = Queue.new
    acknowledgement_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    allow_any_instance_of(DiscussionBridge::PublicationWorkRegistry).to receive(
      :supersede_prior_work!,
    ).and_wrap_original do |original, *args, **kwargs|
      generation_holds_locks << database_pid
      continue_generation.pop
      original.call(*args, **kwargs)
    end
    generation_worker = start_worker(generation_result) do
      DiscussionBridge::SourceRevisionMaterializer.call(
        record: DiscussionBridgeBridgeRecord.find(source.fetch(:record).id),
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
        force_revision: true,
      )
    end
    generation_pid = wait_for(generation_holds_locks)

    acknowledgement_worker = start_worker(acknowledgement_result) do
      acknowledgement_pid << database_pid
      DiscussionBridge::PublicationWorkRegistry.acknowledge(
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
        work_id: source.fetch(:work).work_id,
        payload: source.fetch(:deployed_payload),
      )
    end
    wait_for_database_lock(wait_for(acknowledgement_pid), blocking_pid: generation_pid)
    continue_generation << true
    wait_for(generation_worker)
    wait_for(acknowledgement_worker)

    expect(generation_result.pop).to be_a(DiscussionBridge::SourceRevisionMaterializer::Result)
    acknowledgement_error = acknowledgement_result.pop
    expect(acknowledgement_error).to be_a(DiscussionBridge::AdapterRequestBoundary::Error)
    expect(acknowledgement_error.error_code).to eq("work_superseded")
    expect(source.fetch(:work).reload).to have_attributes(
      state: "superseded",
      last_acknowledged_stage: "synchronized",
    )
    expect(source.fetch(:binding).reload).to have_attributes(
      deployment_state: "pending",
      verification_state: "pending",
    )
    expect(source.fetch(:record).reload.source_revisions.count).to eq(2)
    expect(source.fetch(:connection).publication_works.where(state: "available").count).to eq(1)
  ensure
    continue_generation << true if defined?(continue_generation) && generation_worker&.alive?
  end

  it "commits a late deployment acknowledgement before waiting generation supersedes it" do
    source = prepare_expired_static_work
    update_source_post!(source.fetch(:post))
    acknowledgement_holds_locks = Queue.new
    continue_acknowledgement = Queue.new
    acknowledgement_result = Queue.new
    generation_pid = Queue.new
    generation_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    acknowledgement_worker = start_worker(acknowledgement_result) do
      backend_pid = database_pid
      registry = DiscussionBridge::PublicationWorkRegistry.new(
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
      )
      validate = registry.method(:validate_acknowledgement!)
      registry.define_singleton_method(:validate_acknowledgement!) do |work, payload|
        acknowledgement_holds_locks << backend_pid
        continue_acknowledgement.pop
        validate.call(work, payload)
      end
      registry.acknowledge(
        work_id: source.fetch(:work).work_id,
        payload: source.fetch(:deployed_payload),
      )
    end
    acknowledgement_pid = wait_for(acknowledgement_holds_locks)

    generation_worker = start_worker(generation_result) do
      generation_pid << database_pid
      DiscussionBridge::SourceRevisionMaterializer.call(
        record: DiscussionBridgeBridgeRecord.find(source.fetch(:record).id),
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
        force_revision: true,
      )
    end
    wait_for_database_lock(wait_for(generation_pid), blocking_pid: acknowledgement_pid)
    continue_acknowledgement << true
    wait_for(acknowledgement_worker)
    wait_for(generation_worker)

    accepted = acknowledgement_result.pop
    expect(accepted).to include(
      resulting_state: "awaiting_verification",
      terminal: false,
    )
    expect(generation_result.pop).to be_a(DiscussionBridge::SourceRevisionMaterializer::Result)
    expect(source.fetch(:work).reload).to have_attributes(
      state: "superseded",
      last_acknowledged_stage: "deployed",
    )
    expect(source.fetch(:binding).reload).to have_attributes(
      deployment_state: "deployed",
      verification_state: "pending",
    )
    expect(source.fetch(:record).reload.source_revisions.count).to eq(2)
    expect(source.fetch(:connection).publication_works.where(state: "available").count).to eq(1)
    replay = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: source.fetch(:connection).reload,
      work_id: source.fetch(:work).work_id,
      payload: source.fetch(:deployed_payload),
    )
    expect(replay).to eq(accepted)
    changed = source.fetch(:deployed_payload).merge("correlation_id" => "changed-r3-f15-deployed")
    expect do
      DiscussionBridge::PublicationWorkRegistry.acknowledge(
        connection: source.fetch(:connection).reload,
        work_id: source.fetch(:work).work_id,
        payload: changed,
      )
    end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) do |error|
      expect(error.error_code).to eq("stage_conflict")
    end
    expect(source.fetch(:work).acknowledgements.where(stage: "deployed").count).to eq(1)
  ensure
    continue_acknowledgement << true if
      defined?(continue_acknowledgement) && acknowledgement_worker&.alive?
  end

  it "lets generation supersede expired static work before a late deployment failure" do
    source = prepare_expired_static_work
    update_source_post!(source.fetch(:post))
    failure = failure_payload(source, error_code: "deploy_failed", suffix: "generation-first")
    generation_holds_locks = Queue.new
    continue_generation = Queue.new
    generation_result = Queue.new
    failure_pid = Queue.new
    failure_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    allow_any_instance_of(DiscussionBridge::PublicationWorkRegistry).to receive(
      :supersede_prior_work!,
    ).and_wrap_original do |original, *args, **kwargs|
      generation_holds_locks << database_pid
      continue_generation.pop
      original.call(*args, **kwargs)
    end
    generation_worker = start_worker(generation_result) do
      DiscussionBridge::SourceRevisionMaterializer.call(
        record: DiscussionBridgeBridgeRecord.find(source.fetch(:record).id),
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
        force_revision: true,
      )
    end
    generation_pid = wait_for(generation_holds_locks)

    failure_worker = start_worker(failure_result) do
      failure_pid << database_pid
      DiscussionBridge::PublicationWorkRegistry.fail(
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
        work_id: source.fetch(:work).work_id,
        payload: failure,
      )
    end
    wait_for_database_lock(wait_for(failure_pid), blocking_pid: generation_pid)
    continue_generation << true
    wait_for(generation_worker)
    wait_for(failure_worker)

    expect(generation_result.pop).to be_a(DiscussionBridge::SourceRevisionMaterializer::Result)
    error = failure_result.pop
    expect(error).to be_a(DiscussionBridge::AdapterRequestBoundary::Error)
    expect(error.error_code).to eq("work_superseded")
    expect(source.fetch(:work).reload).to have_attributes(
      state: "superseded",
      last_acknowledged_stage: "synchronized",
      failure_request_digest: nil,
      failure_response_payload: nil,
      failure_code: nil,
      failure_detail: nil,
    )
    expect(source.fetch(:binding).reload).to have_attributes(
      deployment_state: "pending",
      verification_state: "pending",
    )
    expect(source.fetch(:connection).publication_works.where(state: "available").count).to eq(1)
  ensure
    continue_generation << true if defined?(continue_generation) && generation_worker&.alive?
  end

  it "commits a post-sync failure before waiting generation and preserves exact replay" do
    source = prepare_expired_static_work
    update_source_post!(source.fetch(:post))
    failure = failure_payload(source, error_code: "deploy_failed", suffix: "failure-first")
    failure_holds_locks = Queue.new
    continue_failure = Queue.new
    failure_result = Queue.new
    generation_pid = Queue.new
    generation_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    failure_worker = start_worker(failure_result) do
      backend_pid = database_pid
      registry = DiscussionBridge::PublicationWorkRegistry.new(
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
      )
      validate = registry.method(:validate_failure!)
      registry.define_singleton_method(:validate_failure!) do |work, payload|
        failure_holds_locks << backend_pid
        continue_failure.pop
        validate.call(work, payload)
      end
      registry.fail(work_id: source.fetch(:work).work_id, payload: failure)
    end
    failure_pid = wait_for(failure_holds_locks)

    generation_worker = start_worker(generation_result) do
      generation_pid << database_pid
      DiscussionBridge::SourceRevisionMaterializer.call(
        record: DiscussionBridgeBridgeRecord.find(source.fetch(:record).id),
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
        force_revision: true,
      )
    end
    wait_for_database_lock(wait_for(generation_pid), blocking_pid: failure_pid)
    continue_failure << true
    wait_for(failure_worker)
    wait_for(generation_worker)

    accepted = failure_result.pop
    expect(accepted).to include(resulting_state: "retry_wait", attempt_count: 1)
    expect(generation_result.pop).to be_a(DiscussionBridge::SourceRevisionMaterializer::Result)
    expect(source.fetch(:work).reload).to have_attributes(
      state: "superseded",
      last_acknowledged_stage: "synchronized",
      failure_code: "deploy_failed",
      failure_detail: "R3-F15 failure-first",
    )
    expect(source.fetch(:work).failure_request_digest).to be_present
    expect(source.fetch(:work).failure_response_payload).to be_present
    expect(source.fetch(:binding).reload).to have_attributes(deployment_state: "failed")
    replay = DiscussionBridge::PublicationWorkRegistry.fail(
      connection: source.fetch(:connection).reload,
      work_id: source.fetch(:work).work_id,
      payload: failure,
    )
    expect(replay).to eq(accepted)
    changed = failure.merge("error_detail" => "Changed failure detail")
    expect do
      DiscussionBridge::PublicationWorkRegistry.fail(
        connection: source.fetch(:connection).reload,
        work_id: source.fetch(:work).work_id,
        payload: changed,
      )
    end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) do |error|
      expect(error.error_code).to eq("operation_replay_mismatch")
    end
    expect(source.fetch(:connection).publication_works.where(state: "available").count).to eq(1)
  ensure
    continue_failure << true if defined?(continue_failure) && failure_worker&.alive?
  end

  it "commits a post-deploy verification failure before waiting generation" do
    source = prepare_expired_static_work
    deployed = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: source.fetch(:connection),
      work_id: source.fetch(:work).work_id,
      payload: source.fetch(:deployed_payload),
    )
    expect(deployed).to include(resulting_state: "awaiting_verification", terminal: false)
    update_source_post!(source.fetch(:post))
    failure = failure_payload(
      source,
      error_code: "public_verification_failed",
      suffix: "verification-failure-first",
    )
    failure_holds_locks = Queue.new
    continue_failure = Queue.new
    failure_result = Queue.new
    generation_pid = Queue.new
    generation_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    failure_worker = start_worker(failure_result) do
      backend_pid = database_pid
      registry = DiscussionBridge::PublicationWorkRegistry.new(
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
      )
      validate = registry.method(:validate_failure!)
      registry.define_singleton_method(:validate_failure!) do |work, payload|
        failure_holds_locks << backend_pid
        continue_failure.pop
        validate.call(work, payload)
      end
      registry.fail(work_id: source.fetch(:work).work_id, payload: failure)
    end
    failure_pid = wait_for(failure_holds_locks)

    generation_worker = start_worker(generation_result) do
      generation_pid << database_pid
      DiscussionBridge::SourceRevisionMaterializer.call(
        record: DiscussionBridgeBridgeRecord.find(source.fetch(:record).id),
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
        force_revision: true,
      )
    end
    wait_for_database_lock(wait_for(generation_pid), blocking_pid: failure_pid)
    continue_failure << true
    wait_for(failure_worker)
    wait_for(generation_worker)

    expect(failure_result.pop).to include(resulting_state: "retry_wait", attempt_count: 1)
    expect(generation_result.pop).to be_a(DiscussionBridge::SourceRevisionMaterializer::Result)
    expect(source.fetch(:work).reload).to have_attributes(
      state: "superseded",
      last_acknowledged_stage: "deployed",
      failure_code: "public_verification_failed",
    )
    expect(source.fetch(:binding).reload).to have_attributes(
      deployment_state: "deployed",
      verification_state: "failed",
    )
    expect(source.fetch(:connection).publication_works.where(state: "available").count).to eq(1)
  ensure
    continue_failure << true if defined?(continue_failure) && failure_worker&.alive?
  end

  it "keeps terminal verification acknowledged when it wins before generation" do
    source = prepare_expired_static_work
    deployed = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: source.fetch(:connection),
      work_id: source.fetch(:work).work_id,
      payload: source.fetch(:deployed_payload),
    )
    verified_payload = verified_payload(source, deployed.fetch(:next_stage_token))
    update_source_post!(source.fetch(:post))
    verification_holds_locks = Queue.new
    continue_verification = Queue.new
    verification_result = Queue.new
    generation_pid = Queue.new
    generation_result = Queue.new
    ActiveRecord::Base.connection_pool.release_connection

    verification_worker = start_worker(verification_result) do
      backend_pid = database_pid
      registry = DiscussionBridge::PublicationWorkRegistry.new(
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
      )
      validate = registry.method(:validate_acknowledgement!)
      registry.define_singleton_method(:validate_acknowledgement!) do |work, payload|
        verification_holds_locks << backend_pid
        continue_verification.pop
        validate.call(work, payload)
      end
      registry.acknowledge(work_id: source.fetch(:work).work_id, payload: verified_payload)
    end
    verification_pid = wait_for(verification_holds_locks)

    generation_worker = start_worker(generation_result) do
      generation_pid << database_pid
      DiscussionBridge::SourceRevisionMaterializer.call(
        record: DiscussionBridgeBridgeRecord.find(source.fetch(:record).id),
        connection: DiscussionBridgeContentConnection.find(source.fetch(:connection).id),
        force_revision: true,
      )
    end
    wait_for_database_lock(wait_for(generation_pid), blocking_pid: verification_pid)
    continue_verification << true
    wait_for(verification_worker)
    wait_for(generation_worker)

    accepted = verification_result.pop
    expect(accepted).to include(resulting_state: "acknowledged", terminal: true)
    expect(generation_result.pop).to be_a(DiscussionBridge::SourceRevisionMaterializer::Result)
    expect(source.fetch(:work).reload).to have_attributes(
      state: "acknowledged",
      last_acknowledged_stage: "verified",
    )
    expect(source.fetch(:binding).reload).to have_attributes(
      deployment_state: "deployed",
      verification_state: "verified",
    )
    expect(source.fetch(:connection).publication_works.where(state: "available").count).to eq(1)
    replay = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: source.fetch(:connection).reload,
      work_id: source.fetch(:work).work_id,
      payload: verified_payload,
    )
    expect(replay).to eq(accepted)
    expect(source.fetch(:work).acknowledgements.where(stage: "verified").count).to eq(1)
  ensure
    continue_verification << true if
      defined?(continue_verification) && verification_worker&.alive?
  end

  it "rolls back work and binding mutations when post-lock persistence fails" do
    source = prepare_expired_static_work
    work_before = source.fetch(:work).attributes
    binding_before = source.fetch(:binding).attributes
    registry = DiscussionBridge::PublicationWorkRegistry.new(connection: source.fetch(:connection))
    apply = registry.method(:apply_acknowledgement!)
    registry.define_singleton_method(:apply_acknowledgement!) do |work, payload|
      apply.call(work, payload)
      raise ActiveRecord::RecordInvalid.new(work)
    end

    expect do
      registry.acknowledge(
        work_id: source.fetch(:work).work_id,
        payload: source.fetch(:deployed_payload),
      )
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(source.fetch(:work).reload.attributes).to eq(work_before)
    expect(source.fetch(:binding).reload.attributes).to eq(binding_before)
    expect(source.fetch(:work).acknowledgements.where(stage: "deployed")).to be_empty

    failure = failure_payload(source, error_code: "deploy_failed", suffix: "rollback")
    registry = DiscussionBridge::PublicationWorkRegistry.new(connection: source.fetch(:connection).reload)
    mark_failure = registry.method(:mark_binding_failure!)
    registry.define_singleton_method(:mark_binding_failure!) do |work|
      mark_failure.call(work)
      raise ActiveRecord::RecordInvalid.new(work)
    end
    expect do
      registry.fail(work_id: source.fetch(:work).work_id, payload: failure)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(source.fetch(:work).reload.attributes).to eq(work_before)
    expect(source.fetch(:binding).reload.attributes).to eq(binding_before)
  end

  private

  def prepare_expired_static_work
    identity = SecureRandom.hex(6)
    user = Fabricate(
      :admin,
      username: "r3f15#{identity}",
      email: "r3f15#{identity}@example.com",
    )
    @users << user
    SiteSetting.discussion_bridge_service_username = user.username
    connection, = DiscussionBridgeContentConnection.issue!(
      name: "R3-F15 #{identity}",
      platform: "astro",
      allowed_origins: ["https://publisher.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: ["articles"],
      destination_policies: [static_policy(identity)],
      catalog_required: true,
      policy_revision: "policy:r3-f15:#{identity}",
    )
    @connection_ids << connection.id
    @connection_public_ids << connection.public_id
    install_catalog!(connection, identity)

    topic = Fabricate(:topic, user: user, title: "R3-F15 #{identity}", visible: true)
    post = Fabricate(:post, topic: topic, user: user, post_number: 1, raw: "Publication body")
    @topic_ids << topic.id
    record = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: user,
      connection_id: connection.id,
      topic_id: topic.id,
      external_id: "r3-f15-#{identity}",
      canonical_url: "https://publisher.example/articles/#{identity}/",
      lane: "articles",
      native_materialization: true,
    ).record
    @record_ids << record.id
    DiscussionBridge::SourceRevisionMaterializer.call(record: record, connection: connection)
    claimed = DiscussionBridge::PublicationWorkRegistry.claim(
      connection: connection,
      worker_id: "r3-f15-worker",
      maximum_items: 1,
      requested_lease_seconds: 60,
      correlation_id: "r3-f15-claim-#{identity}",
    ).sole
    synchronized_at = Time.zone.now.iso8601(6)
    synchronized = acknowledgement_payload(
      claimed: claimed,
      record: record,
      correlation_id: "r3-f15-synchronized-#{identity}",
      stage: "synchronized",
      stage_token: claimed.fetch(:stage_token),
      synchronized_at: synchronized_at,
      deployment_state: "pending",
      verification_state: "pending",
    )
    synchronized_result = DiscussionBridge::PublicationWorkRegistry.acknowledge(
      connection: connection,
      work_id: claimed.fetch(:work_id),
      payload: synchronized,
    )
    work = DiscussionBridgePublicationWork.find_by!(work_id: claimed.fetch(:work_id))
    travel_to(work.lease_expires_at + 1.second)
    deployed_payload = acknowledgement_payload(
      claimed: claimed,
      record: record,
      correlation_id: "r3-f15-deployed-#{identity}",
      stage: "deployed",
      stage_token: synchronized_result.fetch(:next_stage_token),
      synchronized_at: synchronized_at,
      deployment_state: "deployed",
      verification_state: "pending",
      deployed_at: (Time.zone.parse(synchronized_at) + 1.second).iso8601(6),
    )
    {
      connection: connection,
      record: record,
      binding: record.active_binding("presentation"),
      topic: topic,
      post: post,
      work: work,
      claimed: claimed,
      synchronized_at: synchronized_at,
      deployed_payload: deployed_payload,
    }
  end

  def static_policy(identity)
    {
      "destination_policy_id" => "destination:astro:articles:#{identity}",
      "profile" => "astro",
      "presentation_mode" => "interactive",
      "container_mapping" => {
        "source" => "discourse:category:articles",
        "destination" => "site:articles",
      },
      "taxonomy_mapping" => { "mode" => "source_attribution" },
      "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => {
        "maximum_bytes" => 49_152,
        "overflow_behavior" => "excerpt_with_read_more",
      },
      "catalog_revision" => "catalog:astro:#{identity}",
    }
  end

  def install_catalog!(connection, identity)
    catalog = connection.platform_catalogs.create!(
      platform_profile: "astro",
      catalog_revision: "catalog:astro:#{identity}",
      current: true,
    )
    @catalog_ids << catalog.id
    {
      "containers" => [
        { "id" => "site:articles", "name" => "Articles", "kind" => "route", "available" => true },
      ],
      "taxonomies" => [],
      "terms" => [],
      "authors" => [],
      "presentation_modes" => [
        { "id" => "interactive", "name" => "Interactive", "available" => true },
      ],
      "native_limits" => [
        {
          "id" => "astro:content",
          "name" => "Astro content",
          "maximum_bytes" => 49_152,
          "overflow_behavior" => "excerpt_with_read_more",
          "available" => true,
        },
      ],
    }.each do |segment_type, items|
      catalog.segments.create!(segment_type: segment_type, items: items)
    end
  end

  def acknowledgement_payload(claimed:, record:, correlation_id:, stage:, stage_token:,
                              synchronized_at:, deployment_state:, verification_state:,
                              deployed_at: nil, publicly_verified_at: nil)
    payload = {
      "lease_token" => claimed.fetch(:lease_token),
      "resource_id" => record.resource_id,
      "source_revision" => claimed.fetch(:source_revision),
      "source_revision_sequence" => claimed.fetch(:source_revision_sequence),
      "policy_revision" => claimed.fetch(:policy_revision),
      "destination_policy_id" => claimed.fetch(:destination_policy_id),
      "action" => claimed.fetch(:action),
      "stage" => stage,
      "stage_token" => stage_token,
      "destination_binding" => {
        "binding_id" => record.active_binding("presentation").binding_id,
        "external_id" => record.active_binding("presentation").external_id,
        "canonical_url" => record.active_binding("presentation").canonical_url,
        "publication_revision" => "astro:revision:r3-f15",
        "content_disposition" => "complete",
      },
      "synchronized_at" => synchronized_at,
      "deployment_state" => deployment_state,
      "verification_state" => verification_state,
      "correlation_id" => correlation_id,
    }
    payload["deployed_at"] = deployed_at if deployed_at
    payload["publicly_verified_at"] = publicly_verified_at if publicly_verified_at
    payload
  end

  def verified_payload(source, stage_token)
    deployed_at = source.fetch(:deployed_payload).fetch("deployed_at")
    acknowledgement_payload(
      claimed: source.fetch(:claimed),
      record: source.fetch(:record),
      correlation_id: "r3-f15-verified-#{source.fetch(:record).id}",
      stage: "verified",
      stage_token: stage_token,
      synchronized_at: source.fetch(:synchronized_at),
      deployment_state: "deployed",
      verification_state: "verified",
      deployed_at: deployed_at,
      publicly_verified_at: (Time.zone.parse(deployed_at) + 1.second).iso8601(6),
    )
  end

  def failure_payload(source, error_code:, suffix:)
    {
      "lease_token" => source.fetch(:claimed).fetch(:lease_token),
      "error_code" => error_code,
      "error_detail" => "R3-F15 #{suffix}",
      "failed_at" => Time.zone.now.iso8601(6),
      "correlation_id" => "r3-f15-#{suffix}-#{source.fetch(:record).id}",
    }
  end

  def update_source_post!(post)
    post.update_columns(
      raw: "Newer publication body",
      cooked: "<p>Newer publication body</p>",
      version: post.version + 1,
      updated_at: 1.minute.from_now,
    )
  end

  def start_worker(result, &block)
    Thread.new do
      begin
        ActiveRecord::Base.connection_pool.with_connection { result << block.call }
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

  def wait_for_database_lock(backend_pid, blocking_pid:)
    observer = PG.connect(dbname: ActiveRecord::Base.connection_db_config.database)
    Timeout.timeout(15) do
      loop do
        result = observer.exec_params(
          <<~SQL,
            SELECT wait_event_type, $2::integer = ANY(pg_blocking_pids(pid)) AS intended_blocker
            FROM pg_stat_activity
            WHERE pid = $1
          SQL
          [Integer(backend_pid), Integer(blocking_pid)],
        )
        return if result.ntuples == 1 &&
          result.getvalue(0, 0) == "Lock" && result.getvalue(0, 1) == "t"

        sleep 0.01
      end
    end
  ensure
    observer&.close
  end

  def cleanup_created_rows
    work_scope = DiscussionBridgePublicationWork.where(bridge_record_id: @record_ids)
    DiscussionBridgePublicationAcknowledgement.where(publication_work_id: work_scope).delete_all
    work_scope.delete_all
    DiscussionBridgeSourceSnapshotItem.where(source_snapshot_id: DiscussionBridgeSourceSnapshot.where(
      content_connection_id: @connection_ids,
    )).delete_all
    DiscussionBridgeSourceSnapshot.where(content_connection_id: @connection_ids).delete_all
    DiscussionBridgeSourceRevision.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgeSourceRevocation.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgeContentBinding.where(bridge_record_id: @record_ids).delete_all
    DiscussionBridgeSourceAuthor.where(content_connection_id: @connection_ids).delete_all
    DiscussionBridgePlatformCatalogSegment.where(platform_catalog_id: @catalog_ids).delete_all
    DiscussionBridgePlatformCatalog.where(id: @catalog_ids).delete_all
    DiscussionBridgeAuditEvent.where(connection_id: @connection_public_ids).delete_all
    DiscussionBridgeBridgeRecord.where(id: @record_ids).delete_all
    Post.where(topic_id: @topic_ids).delete_all
    Topic.where(id: @topic_ids).delete_all
    DiscussionBridgeContentConnection.where(id: @connection_ids).delete_all
    @users.reverse_each { |user| user.destroy! if User.exists?(user.id) }
  end
end
