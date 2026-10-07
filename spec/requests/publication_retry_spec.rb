# frozen_string_literal: true

require "rails_helper"
require_relative "../../db/migrate/20261007000007_retain_publication_retry_authorizations"

describe "DiscussionBridge native operator publication Retry" do
  fab!(:admin)
  fab!(:user)
  fab!(:moderator)
  fab!(:category)

  before do |example|
    freeze_time(Time.now.utc.change(usec: 0))
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Operator Retry", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    configure(example.metadata[:profile] || "ghost")
  end

  def configure(profile)
    @connection.update!(platform: profile.start_with?("statamic_") ? "statamic" : profile)
    catalog = { "platform_profile" => profile, "base_catalog_revision" => "catalog:empty", "correlation_id" => "retry-test",
      "segments" => [
        { "segment_type" => "containers", "items" => [{ "id" => "posts", "name" => "Posts", "kind" => "post", "available" => true }] },
        { "segment_type" => "presentation_modes", "items" => [{ "id" => "interactive", "name" => "Interactive", "available" => true }] },
        { "segment_type" => "native_limits", "items" => [{ "id" => "body", "name" => "Body", "maximum_bytes" => 500_000,
          "overflow_behavior" => "excerpt_with_read_more", "available" => true }] },
      ] }
    @connection.with_lock { DiscussionBridge::PlatformCatalog.replace!(@connection, catalog) }
    definition = { "destination_policy_id" => "primary", "profile" => profile, "presentation_mode" => "interactive",
      "container_mapping" => { "source" => "forum", "destination" => "posts" },
      "taxonomy_mapping" => { "mode" => "mapped_only" }, "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => { "maximum_bytes" => 500_000, "overflow_behavior" => "excerpt_with_read_more" },
      "catalog_revision" => DiscussionBridge::PlatformCatalog.current(@connection, profile).public_id }
    @policy = DiscussionBridge::DestinationPolicy.approve!(connection: @connection, definition: definition, actor: admin)
  end

  def publication
    topic = Fabricate(:topic, user: admin, category: category)
    @source = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "Source survives operator Retry.")
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: {
      content_connection_id: @connection.id, external_id: "article:#{topic.id}", canonical_url: "https://native.example/articles/#{topic.id}/",
      presentation_mode: "interactive", native_materialization: true,
    } }, as: :json
    expect([200, 201]).to include(response.status), response.body
    @record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    @binding = @record.active_binding("presentation")
    sign_out
    claim
  end

  def headers
    { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "retry-test",
      "HTTPS" => "on", "CONTENT_TYPE" => "application/json" }
  end

  def claim
    sign_out
    post "/discussion-bridge/v1/publication-work/claim.json", params: JSON.generate("worker_id" => "retry-worker", "correlation_id" => "retry-test"), headers: headers
    expect(response).to have_http_status(:ok), response.body
    @item = response.parsed_body.fetch("publication_work").first
  end

  def failed(code = "identity_conflict")
    publication unless @item
    @work = DiscussionBridgePublicationWork.find_by!(public_id: @item.fetch("work_id"))
    put "/discussion-bridge/v1/publication-work/#{@item.fetch("work_id")}/failure.json", params: JSON.generate(
      "lease_token" => @item.fetch("lease_token"), "error_code" => code, "error_detail" => "The recorded destination condition needs correction.",
      "failed_at" => Time.now.utc.iso8601(6), "correlation_id" => "retry-test"), headers: headers
    expect(response).to have_http_status(:ok), response.body
    @failure = DiscussionBridgePublicationFailure.order(id: :desc).first!
    @work.reload
  end

  def correction
    freeze_time(Time.now + 1.second)
    { "failure_id" => @failure.id, "retry_generation" => @work.retry_generation,
      "correction_evidence" => { "error_code" => @failure.request.fetch("error_code"),
        "summary" => "Removed the conflicting destination object without changing the retained target identity.",
        "verification" => "Operator verified the retained target is now writable and the conflict is absent.",
        "reference" => "https://operator.example/verification/#{@failure.id}/", "verified_at" => Time.now.utc.iso8601(9) } }
  end

  def retry_work(request, actor: admin, connection: @connection, name: nil)
    # Each authorization scenario uses a fresh browser session. The source
    # setup logged in an administrator; a logout request is not proof that the
    # next request is anonymous. Assert the native current identity explicitly.
    reset!
    sign_in(actor) if actor
    get "/session/current.json"
    if actor
      expect(response.parsed_body.dig("current_user", "id")).to eq(actor.id), response.body
    else
      expect(response).to have_http_status(:not_found), response.body
    end
    post "/discussion-bridge/admin/content-connections/#{connection.id}/publication-work/#{@work.public_id}/retry.json",
      params: JSON.generate(request), headers: { "CONTENT_TYPE" => "application/json" }
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    if directory && name
      File.binwrite(File.join(directory, "#{name}.json"), response.body)
      File.binwrite(File.join(directory, "#{name}-request.json"), JSON.generate(request))
    end
  end

  def snapshot
    [@work.reload.attributes, @work.publication_destination.reload.attributes, @source.reload.attributes,
      @record.reload.attributes, @binding.reload.attributes, DiscussionBridgePublicationRetry.count,
      DiscussionBridgePublicationFailure.count, DiscussionBridgeWorkIssue.count]
  end

  it "records an authorized correction and resets only the same work's retry generation" do
    failed
    identity = @work.attributes.slice(*DiscussionBridgePublicationWork::IMMUTABLE)
    source = @source.attributes
    binding = @binding.attributes
    request = correction
    retry_work(request, name: "retry-authorized")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to eq("work_id" => @work.public_id, "retry_generation" => 1, "attempt_count" => 1, "state" => "available")
    expect(@work.reload.attributes.slice(*DiscussionBridgePublicationWork::IMMUTABLE)).to eq(identity)
    expect(@source.reload.attributes).to eq(source)
    expect(@binding.reload.attributes).to eq(binding)
    expect(@work.attributes.slice("lease_token", "stage_token", "worker_id", "lease_started_at", "lease_expires_at", "next_retry_at").values).to all(be_nil)
    receipt = DiscussionBridgePublicationRetry.sole
    expect(receipt.actor_id).to eq(admin.id)
    expect(receipt.publication_failure_id).to eq(@failure.id)
    expect(receipt.request).to eq(request)
    expect(receipt.performed_at_raw).to eq(Time.now.utc.iso8601(9))
    expect { receipt.update!(actor: user) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    item = claim
    expect(item.fetch("work_id")).to eq(@work.public_id)
    expect(item.values_at("attempt_count", "retry_generation")).to eq([1, 1])
    expect(item.fetch("lease_token")).not_to eq(@failure.request.fetch("lease_token"))
  end

  it "does not change state without an authenticated native administrator" do
    failed
    request = correction
    previous = snapshot
    [nil, user, moderator].each do |actor|
      retry_work(request, actor: actor)
      expect(response.status).to be_in([403, 404]), "actor=#{actor&.id}, admin=#{actor&.admin?}: #{response.body}"
      expect(snapshot).to eq(previous)
    end
    sign_out
    post "/discussion-bridge/admin/content-connections/#{@connection.id}/publication-work/#{@work.public_id}/retry.json",
      params: JSON.generate(request), headers: headers
    expect(response.status).to be_in([403, 404])
    expect(snapshot).to eq(previous)
  end

  it "rejects inactive, staged, suspended, silenced and system actors even at the service boundary" do
    failed
    request = correction
    previous = snapshot
    [nil, user, Discourse.system_user].each do |actor|
      expect { DiscussionBridge::PublicationRetry.accept!(connection: @connection, public_id: @work.public_id, request: request, actor: actor) }
        .to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /policy_denied/)
    end
    %i[active? staged? suspended? silenced?].each do |method|
      allow(admin).to receive(method).and_return(method != :active?)
      expect { DiscussionBridge::PublicationRetry.accept!(connection: @connection, public_id: @work.public_id, request: request, actor: admin) }
        .to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /policy_denied/)
      allow(admin).to receive(method).and_call_original
    end
    expect(snapshot).to eq(previous)
  end

  it "replays exactly without a second generation and rejects changed replay" do
    failed
    request = correction
    retry_work(request)
    expect(response).to have_http_status(:ok), response.body
    body = response.parsed_body
    previous = snapshot
    freeze_time(Time.now + 1.minute)
    retry_work(request, name: "retry-replay")
    expect(response.parsed_body).to eq(body)
    expect(snapshot).to eq(previous)
    changed = request.deep_dup
    changed["correction_evidence"]["summary"] = "A different correction statement."
    retry_work(changed, name: "retry-changed-replay")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("operation_replay_mismatch")
    expect(snapshot).to eq(previous)
  end

  it "rejects stale generations, a different failure and a mismatched correction code" do
    failed
    request = correction
    previous = snapshot
    [request.merge("retry_generation" => 1), request.merge("failure_id" => @failure.id + 1),
      request.merge("correction_evidence" => request.fetch("correction_evidence").merge("error_code" => "transport_timeout"))].each do |invalid|
      retry_work(invalid)
      expect([409, 422]).to include(response.status), response.body
      expect(snapshot).to eq(previous)
    end
  end

  it "requires bounded secret-free correction evidence recorded after the actual failure" do
    failed
    request = correction
    previous = snapshot
    evidence = request.fetch("correction_evidence")
    invalid_evidence = [evidence.merge("summary" => ""), evidence.merge("verification" => ""), evidence.except("reference"),
      evidence.merge("summary" => "x" * 2049), evidence.merge("verification" => "password=unsafe-value"),
      evidence.merge("reference" => "https://operator.example/check/?token=unsafe-value"), evidence.merge("reference" => "not-a-url"),
      evidence.merge("summary" => "hidden\u0000control"), evidence.merge("verified_at" => @failure.received_at_raw),
      evidence.merge("verified_at" => (Time.now + 1.second).utc.iso8601(9)), evidence.merge("corrected" => true)]
    invalid_evidence.each do |invalid|
      retry_work(request.merge("correction_evidence" => invalid))
      expect([400, 422]).to include(response.status), response.body
      expect(snapshot).to eq(previous)
    end
  end

  it "does not authorize a leased item or a pending automatic retry" do
    failed("transport_timeout")
    request = correction
    previous = snapshot
    retry_work(request)
    expect(response).to have_http_status(:conflict)
    expect(snapshot).to eq(previous)
  end

  it "does not allow the same correction proof to authorize another failed generation" do
    failed
    request = correction
    retry_work(request)
    expect(response).to have_http_status(:ok), response.body
    claim
    failed
    repeated = request.deep_dup
    repeated["failure_id"] = @failure.id
    repeated["retry_generation"] = 1
    freeze_time(Time.now + 1.second)
    repeated["correction_evidence"]["verified_at"] = Time.now.utc.iso8601(9)
    previous = snapshot
    retry_work(repeated)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("reconciliation_required")
    expect(snapshot).to eq(previous)
  end

  it "keeps the same identity after automatic attempts are exhausted" do
    publication
    identity = @item.slice("work_id", "resource_id", "source_revision", "source_revision_sequence", "policy_revision", "destination_policy_id")
    4.times do |index|
      failed("transport_timeout")
      if index < 3
        freeze_time(@work.next_retry_at)
        claim
      end
    end
    expect(@work.state).to eq("operator_attention")
    expect(@work.attempt_count).to eq(4)
    retry_work(correction)
    expect(response).to have_http_status(:ok), response.body
    expect(claim.slice(*identity.keys)).to eq(identity)
    expect(@item.values_at("attempt_count", "retry_generation")).to eq([1, 1])
  end

  it "does not leak or reset another connection's work" do
    failed
    other, = DiscussionBridgeContentConnection.issue!(name: "Other Retry", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    request = correction
    previous = snapshot
    retry_work(request, connection: other)
    expect(response).to have_http_status(:not_found)
    expect(snapshot).to eq(previous)
  end

  it "requires current connection, scope, native visibility and catalog availability" do
    failed
    request = correction
    previous = snapshot
    @connection.update!(enabled: false)
    retry_work(request)
    expect(response).to have_http_status(:forbidden)
    @connection.update!(enabled: true, allowed_origins: ["https://elsewhere.example"])
    retry_work(request)
    expect(response).to have_http_status(:forbidden)
    @connection.update!(allowed_origins: ["https://native.example"])
    topic = @source.topic
    topic.update_columns(deleted_at: Time.now)
    retry_work(request)
    expect(response).to have_http_status(:forbidden)
    topic.update_columns(deleted_at: nil)
    catalog = DiscussionBridge::PlatformCatalog.current(@connection, "ghost")
    segments = catalog.catalog_items.to_a.group_by(&:segment_type).map do |kind, items|
      { "segment_type" => kind, "items" => items.map { |item| item.value.deep_dup } }
    end
    segments.find { |segment| segment["segment_type"] == "containers" }.fetch("items").first["available"] = false
    replacement = { "platform_profile" => "ghost", "base_catalog_revision" => catalog.public_id,
      "correlation_id" => "retry-test", "segments" => segments }
    @connection.with_lock { DiscussionBridge::PlatformCatalog.replace!(@connection, replacement) }
    retry_work(request)
    expect(response).to have_http_status(:forbidden)
    expect(snapshot).to eq(previous)
  end

  it "rejects superseded work rather than changing its source revision" do
    failed
    request = correction
    @work.update!(state: "superseded")
    previous = snapshot
    retry_work(request, name: "retry-superseded")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("work_superseded")
    expect(snapshot).to eq(previous)
  end

  it "rolls back the authorization receipt if resetting the work fails" do
    failed
    request = correction
    previous = snapshot
    allow_any_instance_of(DiscussionBridgePublicationWork).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)
    retry_work(request)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(snapshot).to eq(previous)
  end

  it "rejects oversized, duplicate-key and unknown-field requests before changing work" do
    failed
    request = correction
    previous = snapshot
    retry_work(request.merge("force" => true))
    expect(response).to have_http_status(:bad_request)
    sign_in(admin)
    url = "/discussion-bridge/admin/content-connections/#{@connection.id}/publication-work/#{@work.public_id}/retry.json"
    post url, params: " " * 65_537, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:payload_too_large)
    duplicate = JSON.generate(request).sub('"failure_id":', '"failure_id":1,"failure_id":')
    post url, params: duplicate, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:bad_request)
    expect(snapshot).to eq(previous)
  end

  it "refuses populated rollback without erasing operator evidence" do
    failed
    retry_work(correction)
    expect(response).to have_http_status(:ok)
    previous = snapshot
    expect { RetainPublicationRetryAuthorizations.new.down }.to raise_error(ActiveRecord::IrreversibleMigration, /Retain operator correction/)
    expect(snapshot).to eq(previous)
  end

  it "rejects changed actor attribution and unknown historical receipt context" do
    failed
    request = correction
    retry_work(request)
    expect(response).to have_http_status(:ok)
    receipt = DiscussionBridgePublicationRetry.sole
    DiscussionBridgePublicationRetry.where(id: receipt.id).update_all(actor_id: user.id)
    previous = snapshot
    retry_work(request)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error_code")).to eq("integrity_failed")
    expect(snapshot).to eq(previous)
    DiscussionBridgePublicationRetry.where(id: receipt.id).update_all(actor_id: admin.id, receipt_digest: nil)
    previous = snapshot
    retry_work(request)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("reconciliation_required")
    expect(snapshot).to eq(previous)
  end

  it "preserves synchronized static binding and recovery stage instead of issuing native mutation", profile: "statamic_ssg" do
    publication
    @work = DiscussionBridgePublicationWork.find_by!(public_id: @item.fetch("work_id"))
    acknowledgement = @item.slice("lease_token", "resource_id", "source_revision", "source_revision_sequence", "policy_revision", "destination_policy_id", "action", "stage_token").merge(
      "stage" => "synchronized", "synchronized_at" => Time.now.utc.iso8601(6), "deployment_state" => "pending",
      "verification_state" => "pending", "correlation_id" => "retry-test", "destination_binding" => {
        "binding_id" => @binding.public_id, "external_id" => "static:#{@item.fetch("resource_id")}",
        "canonical_url" => "https://native.example/static/#{@item.fetch("resource_id")}/", "publication_revision" => "static:1",
        "content_disposition" => "complete",
      })
    put "/discussion-bridge/v1/publication-work/#{@item.fetch("work_id")}/acknowledgement.json", params: JSON.generate(acknowledgement), headers: headers
    expect(response).to have_http_status(:ok), response.body
    binding = @work.publication_destination.reload.binding.deep_dup
    original = @binding.attributes
    failed("operator_action_required")
    expect(@work.retry_resume_state).to eq("awaiting_deployment")
    retry_work(correction, name: "retry-static")
    expect(response).to have_http_status(:ok), response.body
    expect(@work.reload.retry_resume_state).to eq("awaiting_deployment")
    expect(@work.publication_destination.reload.binding).to eq(binding)
    expect(@binding.reload.attributes).to eq(original)
    expect(claim).to be_nil
    expect(DiscussionBridgeWorkIssue.count).to eq(1)
    expect(DiscussionBridgePublicationReceipt.count).to eq(1)
    expect(@work.reload.state).to eq("available")
  end

  it "does not reset work governed by a now-replaced approved policy" do
    failed
    request = correction
    revised = @policy.definition.deep_dup
    revised["author_mapping"] = { "mode" => "mapped_only" }
    replacement = DiscussionBridge::DestinationPolicy.approve!(connection: @connection, definition: revised, actor: admin)
    expect(replacement.id).not_to eq(@work.destination_policy_id)
    previous = snapshot
    retry_work(request)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error_code")).to eq("policy_denied")
    expect(snapshot).to eq(previous)
  end
end
