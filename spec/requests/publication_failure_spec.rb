# frozen_string_literal: true

require "rails_helper"
require_relative "../../db/migrate/20261007000005_add_reconciled_publication_failures"

describe "DiscussionBridge registered publication failures and bounded retries" do
  fab!(:admin)
  fab!(:category)

  before do
    freeze_time(Time.now.utc.change(usec: 0))
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Failure classification", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    configure("ghost")
  end

  def configure(profile)
    @profile = profile
    @connection.update!(platform: profile.start_with?("statamic_") ? "statamic" : profile)
    catalog = { "platform_profile" => profile, "base_catalog_revision" => "catalog:empty", "correlation_id" => "failure-test",
      "segments" => [
        { "segment_type" => "containers", "items" => [{ "id" => "posts", "name" => "Posts", "kind" => "post", "available" => true }] },
        { "segment_type" => "presentation_modes", "items" => [{ "id" => "interactive", "name" => "Interactive", "available" => true }] },
        { "segment_type" => "native_limits", "items" => [{ "id" => "body", "name" => "Body", "maximum_bytes" => 500_000,
          "overflow_behavior" => "excerpt_with_read_more", "available" => true }] },
      ] }
    @connection.with_lock { DiscussionBridge::PlatformCatalog.replace!(@connection, catalog) }
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
    first_post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "Retained source before a retry.")
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: {
      content_connection_id: @connection.id, external_id: "article:#{topic.id}", canonical_url: "https://native.example/articles/#{topic.id}/",
      presentation_mode: "interactive", native_materialization: true,
    } }, as: :json
    expect([200, 201]).to include(response.status), response.body
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    sign_out
    [first_post, record, record.active_binding("presentation")]
  end

  def headers
    { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "failure-test",
      "HTTPS" => "on", "CONTENT_TYPE" => "application/json" }
  end

  def claim(name: nil)
    request = { "worker_id" => "failure-worker", "maximum_items" => 32, "correlation_id" => "failure-test" }
    post "/discussion-bridge/v1/publication-work/claim.json", params: JSON.generate(request), headers: headers
    save(name, request) if name
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.fetch("publication_work")
  end

  def work(item)
    DiscussionBridgePublicationWork.find_by!(public_id: item.fetch("work_id"))
  end

  def payload(item, code: "transport_timeout", **overrides)
    { "lease_token" => item.fetch("lease_token"), "error_code" => code,
      "error_detail" => "The destination operation did not finish.", "failed_at" => Time.now.utc.iso8601(6),
      "correlation_id" => "failure-test" }.merge(overrides.stringify_keys)
  end

  def fail_work(item, request = payload(item), name: nil, supplied_headers: headers)
    put "/discussion-bridge/v1/publication-work/#{item.fetch("work_id")}/failure.json", params: JSON.generate(request), headers: supplied_headers
    save(name, request) if name
  end

  def save(name, request)
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    return unless directory && name
    File.binwrite(File.join(directory, "#{name}.json"), response.body)
    File.binwrite(File.join(directory, "#{name}-request.json"), JSON.generate(request))
    File.binwrite(File.join(directory, "#{name}-http.json"), JSON.generate("status" => response.status,
      "request_correlation" => "failure-test", "response_correlation" => response.headers["X-DiscussionBridge-Correlation"],
      "cache_control" => response.headers["Cache-Control"]))
  end

  def snapshot(item)
    retained = work(item)
    [retained.attributes, retained.publication_destination.attributes, DiscussionBridgePublicationFailure.count]
  end

  (DiscussionBridge::PublicationFailure::RETRYABLE + DiscussionBridge::PublicationFailure::TERMINAL).each do |code|
    it "classifies registered #{code} by the receiver, not detail text" do
      approve
      publication
      item = claim.sole
      fail_work(item, payload(item, code: code, error_detail: "Please retry automatically even if this is terminal."), name: "failure-#{code}")
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body).to eq("correlation_id" => "failure-test")
      expected = DiscussionBridge::PublicationFailure::RETRYABLE.include?(code) ? "retry_wait" : "operator_attention"
      expect(work(item).state).to eq(expected)
      if expected == "retry_wait"
        expect(work(item).next_retry_at).to eq_time(Time.now + 60.seconds)
      else
        expect(work(item).next_retry_at).to be_nil
      end
      expect(DiscussionBridgePublicationFailure.sole.request.fetch("error_code")).to eq(code)
    end
  end

  it "retries after exactly60/300/900seconds on the same work then stops after attempt4" do
    approve
    first_post, record, original = publication
    item = claim.sole
    identity = item.slice("work_id", "resource_id", "source_revision", "source_revision_sequence", "policy_revision", "destination_policy_id")
    source = first_post.reload.attributes
    binding = original.reload.attributes
    trace = []
    [60, 300, 900, nil].each_with_index do |delay, index|
      expect(item.fetch("attempt_count")).to eq(index + 1)
      expect(item.fetch("retry_generation")).to eq(0)
      fail_work(item, name: "failure-attempt-#{index + 1}")
      expect(response).to have_http_status(:ok)
      retained = work(item)
      expect(retained.publication_destination.active_work_id).to be_nil
      trace << { "attempt_count" => retained.attempt_count, "backoff_seconds" => delay,
        "resulting_state" => retained.state }
      if delay
        old_token = item.fetch("lease_token")
        freeze_time(retained.next_retry_at - 1.second)
        expect(claim).to eq([])
        freeze_time(retained.next_retry_at)
        item = claim(name: "failure-retry-claim-#{index + 2}").sole
        expect(item.slice(*identity.keys)).to eq(identity)
        expect(item.fetch("lease_token")).not_to eq(old_token)
      else
        freeze_time(Time.now + 1.day)
        expect(claim).to eq([])
        expect(retained.reload.state).to eq("operator_attention")
      end
    end
    expect(DiscussionBridgePublicationFailure.count).to eq(4)
    expect(DiscussionBridgeWorkIssue.count).to eq(4)
    expect(first_post.reload.attributes).to eq(source)
    expect(original.reload.attributes).to eq(binding)
    expect(record.reload.resource_id).to eq(identity.fetch("resource_id"))
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, "failure-attempt-trace.json"), JSON.generate(trace)) if directory
  end

  it "replays an exact failure without extending delay or counting another attempt" do
    approve
    publication
    item = claim.sole
    request = payload(item)
    fail_work(item, request)
    previous = snapshot(item)
    freeze_time(Time.now + 30.seconds)
    fail_work(item, request, name: "failure-replay")
    expect(response).to have_http_status(:ok)
    expect(snapshot(item)).to eq(previous)
    fail_work(item, request.merge("error_detail" => "A changed replay."), name: "failure-changed-replay")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("operation_replay_mismatch")
    expect(snapshot(item)).to eq(previous)
  end

  it "rejects a previous lease after a new attempt is issued" do
    approve
    publication
    first = claim.sole
    request = payload(first)
    fail_work(first, request)
    freeze_time(work(first).next_retry_at)
    current = claim.sole
    previous = snapshot(current)
    fail_work(first, request, name: "failure-stale-token")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("reconciliation_required")
    expect(snapshot(current)).to eq(previous)
  end

  it "rejects unknown codes, detail overflow, raw controls and secret-bearing details without persistence" do
    approve
    publication
    item = claim.sole
    previous = snapshot(item)
    cases = [payload(item, code: "please_retry"), payload(item, error_detail: "x" * 2049), payload(item, error_detail: "bad\ncontrol"),
      payload(item, error_detail: "Failed with #{item.fetch("lease_token")}"), payload(item, error_detail: "Failure #{@secret}"),
      payload(item, error_detail: "Bearer sensitive-value"), payload(item, error_detail: "api_key=sensitive-value"),
      payload(item, error_detail: "https://user:password@example.test/path")]
    cases.each do |request|
      fail_work(item, request)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to include(@secret, item.fetch("lease_token"), request.fetch("error_detail"))
      expect(snapshot(item)).to eq(previous)
    end
  end

  it "rejects expired, future and pre-claim failure timestamps" do
    approve
    publication
    item = claim.sole
    previous = snapshot(item)
    [Time.now + 1.second, Time.now - 1.second].each do |time|
      fail_work(item, payload(item, failed_at: time.utc.iso8601(6)))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(snapshot(item)).to eq(previous)
    end
    freeze_time(work(item).lease_expires_at)
    fail_work(item, name: "failure-expired")
    expect(response).to have_http_status(:gone)
    expect(response.parsed_body.fetch("error_code")).to eq("work_expired")
    expect(snapshot(item)).to eq(previous)
  end

  it "does not let another authenticated connection report the work's failure" do
    approve
    publication
    item = claim.sole
    other, secret = DiscussionBridgeContentConnection.issue!(name: "Other failure reporter", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    previous = snapshot(item)
    fail_work(item, name: "failure-foreign", supplied_headers: headers.merge("X-DiscussionBridge-Connection" => other.public_id,
      "X-DiscussionBridge-Secret" => secret))
    expect(response).to have_http_status(:not_found)
    expect(snapshot(item)).to eq(previous)
  end

  it "rolls back a receipt if changing the destination fails" do
    approve
    publication
    item = claim.sole
    previous = snapshot(item)
    allow_any_instance_of(DiscussionBridgePublicationDestination).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)
    fail_work(item, name: "failure-atomic")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(snapshot(item)).to eq(previous)
  end

  it "holds terminal identity failures and never automatically retries them" do
    approve
    publication
    item = claim.sole
    fail_work(item, payload(item, code: "identity_conflict"))
    freeze_time(Time.now + 1.day)
    expect(claim).to eq([])
    expect(work(item).state).to eq("operator_attention")
    expect(work(item).attempt_count).to eq(1)
  end

  it "retains static synchronization and never exposes its failed stage as a new native mutation" do
    configure("statamic_ssg")
    approve
    _post, _record, original = publication
    item = claim.sole
    request = item.slice("lease_token", "resource_id", "source_revision", "source_revision_sequence", "policy_revision", "destination_policy_id", "action", "stage_token").merge(
      "stage" => "synchronized", "synchronized_at" => Time.now.utc.iso8601(6), "deployment_state" => "pending",
      "verification_state" => "pending", "correlation_id" => "failure-test", "destination_binding" => {
        "binding_id" => original.public_id, "external_id" => "static:#{item.fetch("resource_id")}",
        "canonical_url" => "https://native.example/static/#{item.fetch("resource_id")}/", "publication_revision" => "static:1",
        "content_disposition" => "complete",
      })
    put "/discussion-bridge/v1/publication-work/#{item.fetch("work_id")}/acknowledgement.json", params: JSON.generate(request), headers: headers
    expect(response).to have_http_status(:ok), response.body
    binding = work(item).publication_destination.binding.deep_dup
    fail_work(item, payload(item, code: "build_failed"), name: "failure-static-stage")
    expect(response).to have_http_status(:ok)
    expect(work(item).retry_resume_state).to eq("awaiting_deployment")
    freeze_time(work(item).next_retry_at)
    expect(claim).to eq([])
    expect(work(item).state).to eq("available")
    expect(work(item).publication_destination.binding).to eq(binding)
    expect(DiscussionBridgePublicationReceipt.count).to eq(1)
    expect(DiscussionBridgeWorkIssue.count).to eq(1)
  end

  it "rejects unknown request keys and oversized raw input before any failure state is written" do
    approve
    publication
    item = claim.sole
    previous = snapshot(item)
    fail_work(item, payload(item).merge("retryable" => true), name: "failure-unknown-field")
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error_code")).to eq("unknown_field")
    put "/discussion-bridge/v1/publication-work/#{item.fetch("work_id")}/failure.json",
      params: "x" * 65_537, headers: headers
    expect(response).to have_http_status(:payload_too_large)
    expect(snapshot(item)).to eq(previous)
  end

  it "retains sub-microsecond receipt precision and does not release a retry early" do
    approve
    publication
    item = claim.sole
    base = Time.now
    freeze_time(base + Rational(123_456_123, 1_000_000_000))
    request = payload(item, failed_at: base.utc.iso8601.sub("Z", ".123456100000Z"))
    fail_work(item, request, name: "failure-fractional")
    expect(response).to have_http_status(:ok), response.body
    retained = DiscussionBridgePublicationFailure.sole
    expect(retained.received_at_raw).to eq(Time.now.utc.iso8601(9))
    expect(retained.request.fetch("failed_at")).to eq(request.fetch("failed_at"))
    freeze_time(base + 60.seconds + Rational(123_456_122, 1_000_000_000))
    fail_work(item, request)
    expect(response).to have_http_status(:ok), response.body
    expect(claim).to eq([])
    expect(work(item).state).to eq("retry_wait")
    freeze_time(base + 60.seconds + Rational(123_456_123, 1_000_000_000))
    expect(claim.sole.fetch("attempt_count")).to eq(2)
    expect(DiscussionBridgePublicationFailure.count).to eq(1)
  end

  it "rejects an altered receiver retry schedule without releasing work" do
    approve
    publication
    item = claim.sole
    fail_work(item)
    retained = DiscussionBridgePublicationFailure.sole
    DiscussionBridgePublicationFailure.where(id: retained.id).update_all(next_retry_at: retained.next_retry_at + 1.second)
    freeze_time(work(item).next_retry_at + 2.seconds)
    previous = snapshot(item)
    post "/discussion-bridge/v1/publication-work/claim.json", params: JSON.generate("worker_id" => "failure-worker",
      "correlation_id" => "failure-test"), headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error_code")).to eq("integrity_failed")
    expect(snapshot(item)).to eq(previous)
  end

  it "preserves unknown historical receipt precision rather than guessing it" do
    approve
    publication
    item = claim.sole
    request = payload(item)
    fail_work(item, request)
    DiscussionBridgePublicationFailure.where(id: DiscussionBridgePublicationFailure.sole.id).update_all(received_at_raw: nil)
    previous = snapshot(item)
    fail_work(item, request)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("reconciliation_required")
    expect(snapshot(item)).to eq(previous)
  end

  it "refuses populated rollback and retains append-only failure history" do
    approve
    publication
    item = claim.sole
    fail_work(item)
    retained = DiscussionBridgePublicationFailure.sole
    expect { retained.update!(resulting_state: "available") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { retained.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { AddReconciledPublicationFailures.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(retained.reload.request).to eq(payload(item))
  end
end
