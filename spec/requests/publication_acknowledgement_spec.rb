# frozen_string_literal: true

require "rails_helper"
require_relative "../../db/migrate/20261007000004_add_reconciled_publication_receipts"

describe "DiscussionBridge exact destination acknowledgement and retained stages" do
  fab!(:admin)
  fab!(:category)

  before do
    freeze_time(Time.now.utc.change(usec: 0))
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Acknowledgements", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    configure_profile("ghost")
  end

  def configure_profile(profile)
    @profile = profile
    @connection.update!(platform: profile.start_with?("statamic_") ? "statamic" : profile == "discourse_as_publisher" ? "discourse" : profile)
    segments = [
      { "segment_type" => "containers", "items" => [{ "id" => "posts", "name" => "Posts", "kind" => "post", "available" => true }] },
      { "segment_type" => "presentation_modes", "items" => [{ "id" => "interactive", "name" => "Interactive", "available" => true }] },
      { "segment_type" => "native_limits", "items" => [{ "id" => "body", "name" => "Body", "maximum_bytes" => 500_000,
        "overflow_behavior" => "excerpt_with_read_more", "available" => true }] },
    ]
    @connection.with_lock do
      DiscussionBridge::PlatformCatalog.replace!(@connection, { "platform_profile" => profile,
        "base_catalog_revision" => "catalog:empty", "segments" => segments, "correlation_id" => "ack-test" })
    end
  end

  def approve(id = "primary")
    definition = { "destination_policy_id" => id, "profile" => @profile, "presentation_mode" => "interactive",
      "container_mapping" => { "source" => "forum", "destination" => "posts" },
      "taxonomy_mapping" => { "mode" => "mapped_only" }, "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => { "maximum_bytes" => 500_000, "overflow_behavior" => "excerpt_with_read_more" },
      "catalog_revision" => DiscussionBridge::PlatformCatalog.current(@connection, @profile).public_id }
    DiscussionBridge::DestinationPolicy.approve!(connection: @connection, definition: definition, actor: admin)
  end

  def publication
    topic = Fabricate(:topic, user: admin, category: category)
    first_post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "A retained source with **rich content**.")
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: {
      content_connection_id: @connection.id, external_id: "article:#{topic.id}", canonical_url: "https://native.example/articles/#{topic.id}/",
      presentation_mode: "interactive", native_materialization: true,
    } }, as: :json
    expect([200, 201]).to include(response.status), response.body
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    sign_out
    [topic, first_post, record, record.active_binding("presentation")]
  end

  def headers
    { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "ack-test",
      "HTTPS" => "on", "CONTENT_TYPE" => "application/json" }
  end

  def claim
    post "/discussion-bridge/v1/publication-work/claim.json",
      params: JSON.generate("worker_id" => "ack-worker", "maximum_items" => 32, "correlation_id" => "ack-test"), headers: headers
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.fetch("publication_work")
  end

  def work
    DiscussionBridgePublicationWork.order(:id).last
  end

  def payload(item, binding_id: "dbb_#{SecureRandom.hex(16)}", external_id: "native:#{item.fetch("resource_id")}", url: nil)
    retained = DiscussionBridgePublicationWork.find_by!(public_id: item.fetch("work_id"))
    pending = retained.destination_mode == "static" ? "pending" : "not_required"
    item.slice("lease_token", "resource_id", "source_revision", "source_revision_sequence", "policy_revision", "destination_policy_id", "action", "stage_token").merge(
      "stage" => "synchronized", "synchronized_at" => Time.now.utc.iso8601(6), "deployment_state" => pending,
      "verification_state" => pending, "correlation_id" => "ack-test", "destination_binding" => {
        "binding_id" => binding_id, "external_id" => external_id,
        "canonical_url" => url || "https://native.example/native/#{item.fetch("resource_id")}/",
        "publication_revision" => "native:revision:1", "content_disposition" => "complete",
      })
  end

  def acknowledge(item, request, name: nil)
    retained = DiscussionBridgePublicationWork.find_by!(public_id: item.fetch("work_id"))
    issued = DiscussionBridgeWorkIssue.where(publication_work_id: retained.id).order(id: :desc).first
    capture = retained.source_inventory_entry.native_source_revision
    acceptance = { "destination_mode" => retained.destination_mode, "received_at" => Time.now.utc.iso8601(6),
      "source_reference" => { "resource_id" => retained.publication_destination.resource_id,
        "source_revision" => capture.revision, "source_revision_sequence" => capture.sequence, "topic_url" => capture.metadata.fetch("topic_url") } }
    acceptance["claimed_at"] = issued.claimed_at.utc.iso8601(6) if request["stage"] == "synchronized"
    context = { "work" => issued.work.merge("stage_token" => retained.stage_token, "lease_expires_at" => retained.lease_expires_at.utc.iso8601(6)),
      "state" => retained.state, "acceptance" => acceptance,
      "wire_headers" => { "request_header" => "ack-test", "response_header" => "ack-test" } }
    put "/discussion-bridge/v1/publication-work/#{item.fetch("work_id")}/acknowledgement.json", params: JSON.generate(request), headers: headers
    context["wire_headers"]["response_header"] = response.headers["X-DiscussionBridge-Correlation"]
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    if name && directory
      File.binwrite(File.join(directory, "#{name}.json"), response.body)
      File.binwrite(File.join(directory, "#{name}-request.json"), JSON.generate(request))
      File.binwrite(File.join(directory, "#{name}-context.json"), JSON.generate(context))
    end
    response.parsed_body
  end

  def show_record(record, name: nil)
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json", headers: headers
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, "#{name}.json"), response.body) if name && directory
    response.parsed_body
  end

  def snapshot(item)
    retained = DiscussionBridgePublicationWork.find_by!(public_id: item.fetch("work_id"))
    [retained.attributes, retained.publication_destination.attributes, DiscussionBridgePublicationReceipt.count]
  end

  it "finishes dynamic synchronization and returns an exact retained replay without changing source rows" do
    approve
    _topic, first_post, record, original = publication
    source = first_post.reload.attributes
    binding = original.attributes
    item = claim.sole
    request = payload(item, binding_id: original.public_id)
    result = acknowledge(item, request, name: "ack-dynamic")
    expect(response).to have_http_status(:ok), response.body
    expect(result).to include("terminal" => true, "resulting_state" => "acknowledged")
    expect(result).not_to have_key("next_stage_token")
    retained = snapshot(item)
    expect(acknowledge(item, request)).to eq(result)
    expect(snapshot(item)).to eq(retained)
    expect(first_post.reload.attributes).to eq(source)
    expect(original.reload.attributes).to eq(binding)
    expect(DiscussionBridgePublicationReceipt.count).to eq(1)
    value = show_record(record, name: "ack-dynamic-record").fetch("bridge_record").fetch("bindings").sole
    expect(value).to include("binding_id" => original.public_id, "applied_source_revision" => item.fetch("source_revision"),
      "deployment_state" => "not_required", "verification_state" => "not_required")
  end

  it "retains the exact source Read More target and raw fractional synchronization timestamp" do
    approve
    topic, _post, record, _binding = publication
    item = claim.sole
    request = payload(item)
    request["destination_binding"].merge!("content_disposition" => "excerpt", "read_more_url" => topic.url)
    request["synchronized_at"] = request.fetch("synchronized_at").sub("000000Z", "123456789123Z")
    freeze_time(Time.now + 1.second)
    acknowledge(item, request, name: "ack-excerpt")
    expect(response).to have_http_status(:ok), response.body
    retained = work.publication_destination.reload.binding
    expect(retained).to include("read_more_url" => topic.url, "synchronized_at" => request.fetch("synchronized_at"))
    expect(show_record(record, name: "ack-excerpt-record").fetch("bridge_record").fetch("bindings").last).to eq(retained)
  end

  it "rejects another source target before persisting an excerpt receipt" do
    approve
    publication
    item = claim.sole
    request = payload(item)
    request["destination_binding"].merge!("content_disposition" => "excerpt", "read_more_url" => "https://forum.example/t/another-source/99")
    previous = snapshot(item)
    acknowledge(item, request, name: "ack-wrong-source")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("identity_conflict")
    expect(snapshot(item)).to eq(previous)
  end

  it "finishes static stages monotonically after lease expiry and keeps exact replay tokens" do
    configure_profile("statamic_ssg")
    approve
    _topic, _post, record, original = publication
    item = claim.sole
    request = payload(item, binding_id: original.public_id)
    synchronized = acknowledge(item, request, name: "ack-static-synchronized")
    expect(response).to have_http_status(:ok), response.body
    expect(synchronized).to include("terminal" => false, "resulting_state" => "awaiting_deployment")
    expect(work.reload.state).to eq("awaiting_deployment")
    expect(show_record(record, name: "ack-static-pending-record").fetch("bridge_record").fetch("bindings").sole.fetch("state")).to eq("pending")
    freeze_time(work.lease_expires_at + 60.seconds)
    expect(claim).to eq([])
    expect(acknowledge(item, request)).to eq(synchronized)
    deployed_request = request.merge("stage" => "deployed", "stage_token" => synchronized.fetch("next_stage_token"),
      "deployment_state" => "deployed", "deployed_at" => Time.now.utc.iso8601(6))
    deployed = acknowledge(item, deployed_request, name: "ack-static-deployed")
    expect(response).to have_http_status(:ok), response.body
    expect(deployed).to include("terminal" => false, "resulting_state" => "awaiting_verification")
    expect(deployed.fetch("next_stage_token")).not_to eq(synchronized.fetch("next_stage_token"))
    verified_request = deployed_request.merge("stage" => "verified", "stage_token" => deployed.fetch("next_stage_token"),
      "verification_state" => "verified", "publicly_verified_at" => Time.now.utc.iso8601(6))
    verified = acknowledge(item, verified_request, name: "ack-static-verified")
    expect(response).to have_http_status(:ok), response.body
    expect(verified).to include("terminal" => true, "resulting_state" => "acknowledged")
    expect(work.reload.publication_destination.reload.active_work_id).to be_nil
    expect(acknowledge(item, deployed_request)).to eq(deployed)
    expect(acknowledge(item, verified_request)).to eq(verified)
    expect(DiscussionBridgePublicationReceipt.count).to eq(3)
    value = show_record(record, name: "ack-static-verified-record").fetch("bridge_record").fetch("bindings").sole
    expect(value).to include("state" => "active", "deployment_state" => "deployed", "verification_state" => "verified",
      "deployed_at" => deployed_request.fetch("deployed_at"), "publicly_verified_at" => verified_request.fetch("publicly_verified_at"))
  end

  it "does not let an adapter downgrade a static destination to dynamic completion" do
    configure_profile("hugo")
    approve
    publication
    item = claim.sole
    request = payload(item).merge("deployment_state" => "not_required", "verification_state" => "not_required")
    previous = snapshot(item)
    acknowledge(item, request, name: "ack-static-downgrade")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("stage_conflict")
    expect(snapshot(item)).to eq(previous)
  end

  it "uses the retained approved profile mode rather than later connection configuration" do
    approve
    publication
    item = claim.sole
    @connection.update!(platform: "hugo")
    result = acknowledge(item, payload(item))
    expect(response).to have_http_status(:ok), response.body
    expect(result.fetch("terminal")).to eq(true)
    expect(work.destination_mode).to eq("dynamic")
  end

  it "preserves unknown old work mode and refuses unclassified acknowledgement" do
    approve
    publication
    item = claim.sole
    request = payload(item)
    work.update_columns(destination_mode: nil)
    previous = snapshot(item)
    acknowledge(item, request, name: "ack-unknown-mode")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("reconciliation_required")
    expect(snapshot(item)).to eq(previous)
  end

  it "rejects wrong identity, revisions, tokens and changed accepted replay without mutation" do
    approve
    publication
    item = claim.sole
    request = payload(item)
    previous = snapshot(item)
    { "resource_id" => SecureRandom.uuid, "source_revision" => "wrong", "policy_revision" => "wrong", "stage_token" => "a" * 64,
      "lease_token" => "b" * 64 }.each do |field, value|
      acknowledge(item, request.merge(field => value))
      expect(response).to have_http_status(:conflict), response.body
      expect(snapshot(item)).to eq(previous)
    end
    acknowledge(item, request)
    expect(response).to have_http_status(:ok), response.body
    accepted = snapshot(item)
    acknowledge(item, request.merge("synchronized_at" => request.fetch("synchronized_at").sub("000000Z", "0000000Z")), name: "ack-changed-replay")
    expect(response).to have_http_status(:conflict)
    expect(snapshot(item)).to eq(accepted)
  end

  it "rejects skipped stages and changed binding or raw synchronization time in later stages" do
    configure_profile("astro")
    approve
    publication
    item = claim.sole
    request = payload(item)
    synchronized = acknowledge(item, request)
    previous = snapshot(item)
    deployed = request.merge("stage" => "deployed", "stage_token" => synchronized.fetch("next_stage_token"),
      "deployment_state" => "deployed", "deployed_at" => Time.now.utc.iso8601(6))
    variants = [deployed.merge("stage" => "verified", "verification_state" => "verified", "publicly_verified_at" => Time.now.utc.iso8601(6)),
      deployed.merge("destination_binding" => request.fetch("destination_binding").merge("publication_revision" => "changed")),
      deployed.merge("synchronized_at" => request.fetch("synchronized_at").sub("000000Z", "0000000Z")),
      deployed.merge("stage_token" => item.fetch("stage_token"))]
    variants.each do |value|
      acknowledge(item, value)
      expect(response).to have_http_status(:conflict), response.body
      expect(snapshot(item)).to eq(previous)
    end
  end

  it "lets an issued older revision finish before releasing its newer independent work" do
    approve
    _topic, first_post, record, original = publication
    item = claim.sole
    request = payload(item, binding_id: original.public_id)
    freeze_time(Time.now + 1.second)
    PostRevisor.new(first_post).revise!(admin, { raw: "A newer source revision." }, force_new_version: true)
    DiscussionBridge::SourceRevisionProducer.call(binding_id: original.id)
    expect(claim).to eq([])
    acknowledge(item, request)
    expect(response).to have_http_status(:ok), response.body
    expect(record.reload.source_revision_sequence).to eq(2)
    expect(show_record(record).fetch("bridge_record").fetch("bindings").sole.fetch("applied_source_revision")).to eq(item.fetch("source_revision"))
    newer = claim.sole
    expect(newer.fetch("source_revision_sequence")).to eq(2)
    second = payload(newer, binding_id: original.public_id, external_id: request.fetch("destination_binding").fetch("external_id"),
      url: request.fetch("destination_binding").fetch("canonical_url"))
    second["destination_binding"]["publication_revision"] = "native:revision:2"
    acknowledge(newer, second, name: "ack-newer")
    expect(response).to have_http_status(:ok), response.body
    expect(show_record(record, name: "ack-newer-record").fetch("bridge_record").fetch("bindings").sole.fetch("publication_revision")).to eq("native:revision:2")
  end

  it "keeps sibling destination bindings distinct and never fans out or overwrites the original row" do
    approve("one")
    approve("two")
    _topic, _post, record, original = publication
    original_attributes = original.attributes
    items = claim
    items.each_with_index do |item, index|
      request = payload(item, binding_id: index.zero? ? original.public_id : "dbb_#{SecureRandom.hex(16)}",
        external_id: "native:#{index}", url: "https://native.example/destinations/#{index}/")
      acknowledge(item, request, name: "ack-sibling-#{index}")
      expect(response).to have_http_status(:ok), response.body
    end
    expect(original.reload.attributes).to eq(original_attributes)
    expect(DiscussionBridgeContentBinding.count).to eq(1)
    values = show_record(record, name: "ack-sibling-record").fetch("bridge_record").fetch("bindings")
    expect(values.size).to eq(2)
    expect(values.map { |binding| binding.fetch("external_id") }).to contain_exactly("native:0", "native:1")
    expect(values.map { |binding| binding.fetch("binding_id") }.uniq.size).to eq(2)
  end

  it "reserves accepted native URL, external identity and binding ID against sibling collisions" do
    approve("one")
    approve("two")
    publication
    first, second = claim
    accepted = payload(first)
    acknowledge(first, accepted)
    expect(response).to have_http_status(:ok), response.body
    previous = snapshot(second)
    %w[binding_id canonical_url external_id].each do |field|
      request = payload(second, url: "https://native.example/second/", external_id: "native:second")
      request["destination_binding"][field] = accepted.fetch("destination_binding").fetch(field)
      acknowledge(second, request, name: "ack-collision-#{field}")
      expect(response).to have_http_status(:conflict), response.body
      expect(response.parsed_body.fetch("error_code")).to eq("destination_collision")
      expect(snapshot(second)).to eq(previous)
    end
  end

  it "preserves legacy identity reservations and rejects native URLs outside authenticated scope" do
    approve
    publication
    _topic, _post, _record, original = publication
    items = claim
    first = items.first
    request = payload(first, binding_id: original.public_id)
    previous = snapshot(first)
    acknowledge(first, request)
    expect(response).to have_http_status(:conflict), response.body
    expect(snapshot(first)).to eq(previous)
    acknowledge(first, payload(first, url: "https://foreign.example/article/"), name: "ack-foreign-origin")
    expect(response).to have_http_status(:forbidden)
    expect(snapshot(first)).to eq(previous)
  end

  it "rolls back binding, work and receipt atomically when receipt persistence fails" do
    approve
    publication
    item = claim.sole
    request = payload(item)
    previous = snapshot(item)
    allow(DiscussionBridgePublicationReceipt).to receive(:create!).and_raise("simulated receipt storage failure")
    acknowledge(item, request, name: "ack-atomic-failure")
    expect(response).to have_http_status(:internal_server_error)
    expect(snapshot(item)).to eq(previous)
    allow(DiscussionBridgePublicationReceipt).to receive(:create!).and_call_original
    acknowledge(item, request)
    expect(response).to have_http_status(:ok), response.body
  end

  it "rejects expired or superseded synchronization without adopting an old token" do
    approve
    _topic, first_post, _record, original = publication
    item = claim.sole
    request = payload(item)
    freeze_time(work.lease_expires_at + 1.second)
    acknowledge(item, request, name: "ack-expired")
    expect(response).to have_http_status(:gone)
    PostRevisor.new(first_post).revise!(admin, { raw: "A new source supersedes expired work." }, force_new_version: true)
    DiscussionBridge::SourceRevisionProducer.call(binding_id: original.id)
    claim
    acknowledge(item, request, name: "ack-superseded")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("work_superseded")
    expect(DiscussionBridgePublicationReceipt.count).to eq(0)
  end

  it "retains immutable receipts and refuses tampered projected binding reads" do
    approve
    _topic, _post, record, _original = publication
    item = claim.sole
    acknowledge(item, payload(item))
    expect { DiscussionBridgePublicationReceipt.sole.update!(request: {}) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { work.update!(destination_mode: "static") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    work.publication_destination.update_columns(binding: {})
    show_record(record)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error_code")).to eq("integrity_failed")
  end

  it "screens actual oversized and duplicate PUT bodies before mutation" do
    approve
    publication
    item = claim.sole
    previous = snapshot(item)
    path = "/discussion-bridge/v1/publication-work/#{item.fetch("work_id")}/acknowledgement.json"
    put path, params: " " * 65_537, headers: headers
    expect(response).to have_http_status(:payload_too_large)
    put path, params: '{"correlation_id":"ack-test","correlation_id":"ack-test"}', headers: headers
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error_code")).to eq("invalid_json")
    request = payload(item).merge("undeclared" => true)
    acknowledge(item, request, name: "ack-unknown-field")
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error_code")).to eq("unknown_field")
    expect(snapshot(item)).to eq(previous)
  end

  it "refuses rollback before removing any retained mode, binding or receipt state" do
    approve
    publication
    expect { AddReconciledPublicationReceipts.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(DiscussionBridgePublicationWork.count).to eq(1)
    expect(DiscussionBridgePublicationDestination.count).to eq(1)
  end

  { "astro" => "static", "ghost" => "dynamic", "hugo" => "static", "statamic_flat" => "dynamic",
    "statamic_db" => "dynamic", "statamic_ssg" => "static", "wordpress" => "dynamic" }.each do |profile, mode|
    it "snapshots and enforces the approved #{profile} native mode" do
      configure_profile(profile) unless profile == "ghost"
      approve
      publication
      item = claim.sole
      expect(work.destination_mode).to eq(mode)
      result = acknowledge(item, payload(item))
      expect(response).to have_http_status(:ok), response.body
      expect(result.fetch("terminal")).to eq(mode == "dynamic")
      expect(result.fetch("resulting_state")).to eq(mode == "dynamic" ? "acknowledged" : "awaiting_deployment")
    end
  end

  it "preserves an excerpt's exact retained source link through every static stage" do
    configure_profile("statamic_ssg")
    approve
    topic, first_post, record, original = publication
    item = claim.sole
    request = payload(item, binding_id: original.public_id)
    request["destination_binding"].merge!("content_disposition" => "excerpt", "read_more_url" => topic.url)
    synchronized = acknowledge(item, request, name: "ack-static-excerpt-synchronized")
    expect(response).to have_http_status(:ok), response.body
    freeze_time(Time.now + 1.second)
    PostRevisor.new(first_post).revise!(admin, { raw: "A newer wiki-ready source." }, force_new_version: true)
    DiscussionBridge::SourceRevisionProducer.call(binding_id: original.id)
    deployed_request = request.merge("stage" => "deployed", "stage_token" => synchronized.fetch("next_stage_token"),
      "deployment_state" => "deployed", "deployed_at" => Time.now.utc.iso8601(6))
    previous = snapshot(item)
    altered = deployed_request.merge("destination_binding" => request.fetch("destination_binding").merge("read_more_url" => "https://forum.example/t/wrong/1"))
    acknowledge(item, altered)
    expect(response).to have_http_status(:conflict)
    expect(snapshot(item)).to eq(previous)
    deployed = acknowledge(item, deployed_request, name: "ack-static-excerpt-deployed")
    expect(response).to have_http_status(:ok), response.body
    verified_request = deployed_request.merge("stage" => "verified", "stage_token" => deployed.fetch("next_stage_token"),
      "verification_state" => "verified", "publicly_verified_at" => Time.now.utc.iso8601(6))
    acknowledge(item, verified_request, name: "ack-static-excerpt-verified")
    expect(response).to have_http_status(:ok), response.body
    value = show_record(record, name: "ack-static-excerpt-record").fetch("bridge_record").fetch("bindings").sole
    expect(value).to include("content_disposition" => "excerpt", "read_more_url" => topic.url, "applied_source_revision" => item.fetch("source_revision"))
    expect(record.reload.source_revision_sequence).to eq(2)
  end

  it "does not expose or acknowledge another authenticated connection's work" do
    approve
    publication
    item = claim.sole
    request = payload(item)
    previous = snapshot(item)
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Foreign connection", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    acknowledge(item, request, name: "ack-foreign-connection")
    expect(response).to have_http_status(:not_found)
    expect(snapshot(item)).to eq(previous)
  end

  it "rejects synchronization before claim or after receipt and future static event times" do
    configure_profile("hugo")
    approve
    publication
    item = claim.sole
    request = payload(item)
    previous = snapshot(item)
    [Time.now - 1.second, Time.now + 1.second].each do |time|
      acknowledge(item, request.merge("synchronized_at" => time.utc.iso8601(6)))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(snapshot(item)).to eq(previous)
    end
    synchronized = acknowledge(item, request)
    expect(response).to have_http_status(:ok), response.body
    accepted = snapshot(item)
    deployed_request = request.merge("stage" => "deployed", "stage_token" => synchronized.fetch("next_stage_token"),
      "deployment_state" => "deployed", "deployed_at" => (Time.now + 1.second).utc.iso8601(6))
    acknowledge(item, deployed_request, name: "ack-future-event")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(snapshot(item)).to eq(accepted)
  end
end
