# frozen_string_literal: true

require "rails_helper"
require_relative "../../db/migrate/20261007000003_add_reconciled_publication_work"

describe "DiscussionBridge retained independent publication work and leases" do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Independent work", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    segments = [
      { "segment_type" => "containers", "items" => [{ "id" => "posts", "name" => "Posts", "kind" => "post", "available" => true }] },
      { "segment_type" => "presentation_modes", "items" => [{ "id" => "interactive", "name" => "Interactive", "available" => true }] },
      { "segment_type" => "native_limits", "items" => [{ "id" => "body", "name" => "Body", "maximum_bytes" => 500_000,
        "overflow_behavior" => "excerpt_with_read_more", "available" => true }] },
    ]
    @connection.with_lock do
      @catalog = DiscussionBridge::PlatformCatalog.replace!(@connection, { "platform_profile" => "ghost",
        "base_catalog_revision" => "catalog:empty", "segments" => segments, "correlation_id" => "work-test" })
    end
  end

  def approve(id = "primary", **overrides)
    definition = { "destination_policy_id" => id, "profile" => "ghost", "presentation_mode" => "interactive",
      "container_mapping" => { "source" => "forum", "destination" => "posts" },
      "taxonomy_mapping" => { "mode" => "mapped_only" }, "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => { "maximum_bytes" => 500_000, "overflow_behavior" => "excerpt_with_read_more" },
      "catalog_revision" => DiscussionBridge::PlatformCatalog.current(@connection, "ghost").public_id }.merge(overrides.stringify_keys)
    DiscussionBridge::DestinationPolicy.approve!(connection: @connection, definition: definition, actor: admin)
  end

  def publication(native_materialization: true)
    topic = Fabricate(:topic, user: admin, category: category)
    first_post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "An authoritative source for independent destinations.")
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: {
      content_connection_id: @connection.id, external_id: "article:#{topic.id}",
      canonical_url: "https://native.example/articles/#{topic.id}/", presentation_mode: "interactive", native_materialization: native_materialization,
    } }, as: :json
    expect([200, 201]).to include(response.status), response.body
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    sign_out
    [topic, first_post, record, record.active_binding("presentation")]
  end

  def headers
    { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "work-test",
      "HTTPS" => "on", "CONTENT_TYPE" => "application/json" }
  end

  def claim(name: nil, **overrides)
    request = { "worker_id" => "native-worker", "correlation_id" => "work-test" }.merge(overrides.stringify_keys)
    post "/discussion-bridge/v1/publication-work/claim.json", params: JSON.generate(request), headers: headers
    save(name, request) if name
    response.parsed_body
  end

  def renew(work, token: work.lease_token, seconds: 300, name: nil)
    request = { "lease_token" => token, "requested_lease_seconds" => seconds, "correlation_id" => "work-test" }
    issue = DiscussionBridgeWorkIssue.where(publication_work_id: work.id).order(id: :desc).first
    context = issue && { "work" => issue.work.merge("lease_expires_at" => work.lease_expires_at.utc.iso8601(6)),
      "state" => work.state, "claimed_at" => work.lease_started_at.utc.iso8601(6),
      "request_received_at" => Time.now.utc.iso8601(6), "current_total_lease_seconds" => work.total_lease_seconds }
    post "/discussion-bridge/v1/publication-work/#{work.public_id}/renew.json", params: JSON.generate(request), headers: headers
    save(name, request) if name
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, "#{name}-context.json"), JSON.generate(context)) if directory && name && response.status == 200
    response.parsed_body
  end

  def save(name, request)
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    return unless directory
    File.binwrite(File.join(directory, "#{name}.json"), response.body)
    File.binwrite(File.join(directory, "#{name}-request.json"), JSON.generate(request))
  end

  def work
    DiscussionBridgePublicationWork.order(:id).last
  end

  def capture_update(first_post, binding)
    PostRevisor.new(first_post).revise!(admin, { raw: "An updated source with **wiki-ready content**." }, force_new_version: true)
    DiscussionBridge::SourceRevisionProducer.call(binding_id: binding.id)
  end

  it "does not create work from descriptive catalog discovery alone" do
    publication
    expect(DiscussionBridgePublicationDestination.count).to eq(0)
    expect(claim(name: "work-empty").fetch("publication_work")).to eq([])
    expect(response).to have_http_status(:ok)
    expect(DiscussionBridgePublicationWork.count).to eq(0)
  end

  it "requires the source's explicit native-materialization permission as well as an approved policy" do
    approve
    publication(native_materialization: false)
    expect(DiscussionBridgePublicationDestination.count).to eq(0)
    expect(claim.fetch("publication_work")).to eq([])
    expect(DiscussionBridgePublicationWork.count).to eq(0)
  end

  it "does not populate old policies on migration or catalog read but permits explicit repeat approval to start a missing cursor" do
    retained = approve
    DiscussionBridgePolicyProduction.where(destination_policy_id: retained.id).delete_all
    publication(native_materialization: false)
    expect(DiscussionBridgePolicyProduction.count).to eq(0)
    expect(approve.id).to eq(retained.id)
    cursor = DiscussionBridgePolicyProduction.sole
    expect(cursor.cut).to eq(DiscussionBridgeSourceInventoryEntry.maximum(:id))
    expect(approve.id).to eq(retained.id)
    expect(DiscussionBridgePolicyProduction.sole.id).to eq(cursor.id)
  end

  it "atomically observes an exact source and creates independently keyed work without changing the original binding" do
    policy = approve
    _topic, first_post, record, binding = publication
    expect(DiscussionBridgePublicationDestination.count).to eq(1)
    expect(work.source_inventory_entry.native_source_revision_id).to eq(record.native_source_revisions.sole.id)
    expect(work.context.fetch("work")).to include("resource_id" => record.resource_id,
      "source_revision" => record.source_revision, "policy_revision" => policy.policy_revision, "action" => "publish")
    source = first_post.reload.attributes
    original_binding = binding.attributes
    value = claim(name: "work-claim").fetch("publication_work").sole
    expect(response).to have_http_status(:ok), response.body
    expect(value).to include("work_id" => work.public_id, "attempt_count" => 1, "retry_generation" => 0)
    expect(value.keys).not_to include("content_html", "policy_definition", "scope_revision", "state", "platform_profile")
    expect(first_post.reload.attributes).to eq(source)
    expect(binding.reload.attributes).to eq(original_binding)
    expect(record.reload.resource_id).to eq(value.fetch("resource_id"))
    expect(DiscussionBridgeWorkIssue.sole.work).to eq(value)
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
  end

  it "isolates two destination policies for the same resource and leases each at most once" do
    approve("one")
    approve("two")
    publication
    value = claim(maximum_items: 32, name: "work-two-destinations").fetch("publication_work")
    expect(value.size).to eq(2)
    expect(value.map { |item| item.fetch("resource_id") }.uniq.size).to eq(1)
    expect(value.map { |item| item.fetch("destination_policy_id") }).to contain_exactly("one", "two")
    expect(value.map { |item| item.fetch("lease_token") }.uniq.size).to eq(2)
    expect(claim(worker_id: "second-worker").fetch("publication_work")).to eq([])
    expect(DiscussionBridgeContentBinding.count).to eq(1)
    expect(DiscussionBridgeWorkIssue.count).to eq(2)
  end

  it "reuses an exact observation and retains immutable issue history" do
    policy = approve
    _topic, _post, record, binding = publication
    entry = DiscussionBridgeSourceInventoryEntry.sole
    @connection.with_lock do
      expect(DiscussionBridge::PublicationWorkProducer.produce!(connection: @connection, entry: entry, policy: policy)).to eq(work)
    end
    expect(DiscussionBridgePublicationWork.count).to eq(1)
    claim
    expect { work.update!(context: {}) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { DiscussionBridgeWorkIssue.sole.update!(work: {}) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(record.reload.native_source_revisions.count).to eq(1)
    expect(binding.reload.state).to eq("active")
  end

  it "supersedes an unissued older source without making it an update or inventing a receipt" do
    approve
    _topic, first_post, _record, binding = publication
    previous = work
    capture_update(first_post, binding)
    expect(previous.reload.state).to eq("superseded")
    expect(work.context.fetch("work")).to include("source_revision_sequence" => 2, "action" => "publish")
    expect(DiscussionBridgeWorkIssue.count).to eq(0)
    expect(claim(name: "work-newer").fetch("publication_work").sole.fetch("source_revision_sequence")).to eq(2)
  end

  it "never changes an active lease when a newer source is observed and serializes the next revision" do
    approve
    _topic, first_post, _record, binding = publication
    claim
    previous = work
    issued = previous.attributes
    capture_update(first_post, binding)
    newer = work
    expect(previous.reload.attributes).to eq(issued)
    expect(newer.context.fetch("work")).to include("action" => "update", "source_revision_sequence" => 2)
    expect(claim.fetch("publication_work")).to eq([])
    freeze_time(previous.lease_expires_at + 1.second)
    value = claim(name: "work-after-supersession").fetch("publication_work").sole
    expect(previous.reload.state).to eq("superseded")
    expect(value.fetch("work_id")).to eq(newer.public_id)
    expect(DiscussionBridgeWorkIssue.order(:id).first.work.fetch("source_revision_sequence")).to eq(1)
    renew(previous)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("work_superseded")
  end

  it "reclaims an expired unacknowledged lease under the same identity with new tokens" do
    approve
    publication
    original = claim.fetch("publication_work").sole
    previous = work
    freeze_time(previous.lease_expires_at + 1.second)
    renew(previous, name: "work-expired-renewal")
    expect(response).to have_http_status(:gone)
    value = claim(name: "work-reclaimed").fetch("publication_work").sole
    expect(value.fetch("work_id")).to eq(original.fetch("work_id"))
    expect(value.fetch("lease_token")).not_to eq(original.fetch("lease_token"))
    expect(value.fetch("stage_token")).not_to eq(original.fetch("stage_token"))
    expect(DiscussionBridgeWorkIssue.count).to eq(2)
    renew(previous.reload, token: original.fetch("lease_token"), name: "work-wrong-token")
    expect(response).to have_http_status(:conflict)
  end

  it "renews only the exact active token within the fixed total duration" do
    approve
    publication
    claim
    previous = work
    expiry = previous.lease_expires_at
    result = renew(previous, seconds: 3600, name: "work-renewal")
    expect(response).to have_http_status(:ok), response.body
    expect(result.fetch("total_lease_seconds")).to eq(3900)
    expect(previous.reload.lease_expires_at).to eq_time(expiry + 3600.seconds)
    2.times { renew(previous.reload, seconds: 3600) }
    unchanged = previous.reload.attributes
    renew(previous, seconds: 3600, name: "work-lease-limit")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error_code")).to eq("lease_limit_exceeded")
    expect(previous.reload.attributes).to eq(unchanged)
  end

  it "returns a bounded batch and uses one coherent post-lock claim clock" do
    approve
    3.times { publication }
    value = claim(maximum_items: 2, requested_lease_seconds: 17, name: "work-bounded-batch")
    expect(value.fetch("publication_work").size).to eq(2)
    expiries = value.fetch("publication_work").map { |item| Time.iso8601(item.fetch("lease_expires_at")) }
    expect(expiries.uniq).to eq([Time.iso8601(value.fetch("claimed_at")) + 17.seconds])
    expect(claim.fetch("publication_work").size).to eq(1)
  end

  it "creates durable policy population progress and resumes without relying on the original queued job" do
    3.times { publication }
    original = DiscussionBridgeContentBinding.order(:id).map(&:attributes)
    policy = approve
    cursor = DiscussionBridgePolicyProduction.find_by!(destination_policy: policy)
    expect(cursor.complete).to eq(false)
    expect(DiscussionBridgePublicationWork.count).to eq(0)
    Jobs::DiscussionBridgeResumePublicationWork.new.execute({})
    expect(cursor.reload.complete).to eq(true)
    expect(cursor.position).to eq(cursor.cut)
    expect(DiscussionBridgePublicationWork.count).to eq(3)
    Jobs::DiscussionBridgeProducePublicationWork.new.execute(production_id: cursor.id)
    expect(DiscussionBridgePublicationWork.count).to eq(3)
    expect(DiscussionBridgeContentBinding.order(:id).map(&:attributes)).to eq(original)
  end

  it "moves the fixed policy cursor through bounded real positions across repeated execution" do
    3.times { publication }
    policy = approve
    cursor = DiscussionBridgePolicyProduction.find_by!(destination_policy: policy)
    positions = []
    stub_const(DiscussionBridge::PublicationWorkProducer, :BATCH_SIZE, 1) do
      3.times do
        DiscussionBridge::PublicationWorkProducer.resume!(cursor.id)
        positions << cursor.reload.position
      end
    end
    expect(positions.uniq.size).to eq(3)
    expect(positions.sort).to eq(positions)
    expect(cursor.complete).to eq(true)
    expect(cursor.position).to eq(cursor.cut)
    expect(DiscussionBridgePublicationWork.count).to eq(3)
  end

  it "retains issued old policy snapshots and waits for the active lease before issuing a new policy" do
    policy = approve
    publication
    claim
    previous = work
    definition = policy.definition.deep_dup
    definition["taxonomy_mapping"] = { "mode" => "source_attribution" }
    next_policy = approve("primary", **definition.symbolize_keys)
    cursor = DiscussionBridgePolicyProduction.find_by!(destination_policy: next_policy)
    DiscussionBridge::PublicationWorkProducer.resume!(cursor.id)
    expect(previous.reload.context.fetch("policy_definition")).to eq(policy.definition)
    expect(work.destination_policy_id).to eq(next_policy.id)
    expect(claim.fetch("publication_work")).to eq([])
    freeze_time(previous.lease_expires_at + 1.second)
    expect(claim.fetch("publication_work").sole.fetch("policy_revision")).to eq(next_policy.policy_revision)
  end

  it "does not issue a now-private or withdrawn source and continues to an eligible destination" do
    approve
    hidden, _post, _record, _binding = publication
    _topic, _post, visible, _binding = publication
    hidden.update!(archetype: Archetype.private_message, category_id: nil)
    value = claim(name: "work-public-only").fetch("publication_work")
    expect(value.map { |item| item.fetch("resource_id") }).to eq([visible.resource_id])
    expect(DiscussionBridgePublicationWork.where(state: "operator_attention").count).to eq(1)
  end

  it "rejects current scope changes without leaking source content or changing the original binding" do
    approve
    _topic, _post, _record, binding = publication
    @connection.update!(allowed_origins: ["https://different.example"])
    expect(claim(name: "work-scope-change").fetch("publication_work")).to eq([])
    expect(binding.reload.state).to eq("active")
    expect(DiscussionBridgeWorkIssue.count).to eq(0)
  end

  it "holds removed catalog mappings without silently remapping or blocking another available policy" do
    approve
    publication
    catalog = DiscussionBridge::PlatformCatalog.current(@connection, "ghost")
    @connection.with_lock do
      DiscussionBridge::PlatformCatalog.replace!(@connection, { "platform_profile" => "ghost",
        "base_catalog_revision" => catalog.public_id, "segments" => [{ "segment_type" => "containers", "items" => [] }],
        "correlation_id" => "work-test" })
    end
    expect(claim(name: "work-catalog-unavailable").fetch("publication_work")).to eq([])
    expect(work.reload.state).to eq("operator_attention")
    expect(work.context.fetch("work").fetch("resolved_container")).to eq("id" => "posts", "kind" => "post")
  end

  it "rejects tampered retained work without issuing a lease or altering sibling state" do
    approve
    publication
    work.update_column(:context_digest, "0" * 64)
    claim(name: "work-tampered")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("reconciliation_required")
    expect(work.reload.state).to eq("available")
    expect(DiscussionBridgeWorkIssue.count).to eq(0)
  end

  it "rolls source observation and work back together if production fails" do
    approve
    allow(DiscussionBridgePublicationWork).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(DiscussionBridgePublicationWork.new))
    topic = Fabricate(:topic, user: admin, category: category)
    Fabricate(:post, topic: topic, user: admin, post_number: 1)
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: {
      content_connection_id: @connection.id, external_id: "failed:#{topic.id}", canonical_url: "https://native.example/failure/",
      presentation_mode: "interactive", native_materialization: true,
    } }, as: :json
    expect(response).not_to have_http_status(:success)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(0)
    expect(DiscussionBridgePublicationDestination.count).to eq(0)
  end

  it "rejects a foreign connection renewal without changing either connection's work" do
    approve
    publication
    claim
    previous = work
    original = previous.attributes
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Foreign", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    renew(previous, name: "work-foreign-renewal")
    expect(response).to have_http_status(:not_found)
    expect(previous.reload.attributes).to eq(original)
  end

  it "screens raw duplicates, unknown fields, correlation and contract before issuing work" do
    approve
    publication
    claim(maximum_items: 33, name: "work-invalid-claim")
    expect(response).to have_http_status(:unprocessable_entity)
    claim(state: "acknowledged")
    expect(response).to have_http_status(:bad_request)
    claim(correlation_id: "different")
    expect(response).to have_http_status(:unprocessable_entity)
    post "/discussion-bridge/v1/publication-work/claim.json",
      params: '{"worker_id":"first","worker_id":"second","correlation_id":"work-test"}', headers: headers
    expect(response.parsed_body.fetch("error_code")).to eq("invalid_json")
    post "/discussion-bridge/v1/publication-work/claim.json", params: '{}', headers: headers.merge("X-DiscussionBridge-Contract" => "old")
    expect(response).to have_http_status(:unauthorized)
    expect(DiscussionBridgeWorkIssue.count).to eq(0)
  end

  it "refuses populated rollback rather than discarding exact work or policy progress" do
    approve
    expect { AddReconciledPublicationWork.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(DiscussionBridgePolicyProduction.count).to eq(1)
  end
end
