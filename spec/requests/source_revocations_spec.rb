# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge durable source withdrawal notices" do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Withdrawal notices", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
  end

  def publication(text: "A native source body that never belongs in a withdrawal response.")
    topic = Fabricate(:topic, user: admin, category: category)
    first_post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: text)
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: {
      content_connection_id: @connection.id, external_id: "article:#{topic.id}",
      canonical_url: "https://native.example/articles/#{topic.id}/", presentation_mode: "interactive",
    } }, as: :json
    expect(response).to have_http_status(:created), response.body
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    sign_out
    [topic, first_post, record, record.active_binding("presentation")]
  end

  def withdraw
    topic, first_post, record, binding = publication
    first_post.update_columns(deleted_at: Time.now.utc)
    notice = DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
    [notice, topic, first_post, record, binding]
  end

  def request_notices(query = {}, resource_id: nil, name: nil, **fields)
    path = resource_id ? "/discussion-bridge/v1/source-revocations/#{resource_id}.json" : "/discussion-bridge/v1/source-revocations.json"
    get path, params: query.merge(fields), headers: {
      "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "withdrawal-test", "HTTPS" => "on",
    }
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, name), response.body) if directory && name
    response.parsed_body
  end

  def resume(value, name: nil)
    request_notices({ high_water: value.fetch("high_water"), cursor: value.fetch("next_cursor"), limit: 1 }, name: name)
  end

  def expect_error(code, status)
    expect(response).to have_http_status(status), response.body
    expect(response.parsed_body).to include("error_code" => code, "correlation_id" => "withdrawal-test")
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
    expect(response.headers["X-DiscussionBridge-Correlation"]).to eq("withdrawal-test")
  end

  it "returns an empty terminal window without manufacturing notices or publication records" do
    value = request_notices({}, name: "revocations-empty.json")
    expect(response).to have_http_status(:ok), response.body
    expect(value).to include("items" => [], "complete" => true, "next_cursor" => nil)
    expect(DiscussionBridgeSourceRevocation.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "records the exact withdrawn revision once without changing source or publication state" do
    notice, topic, first_post, record, binding = withdraw
    expect(notice).to have_attributes(reason: "source_deleted", source_revision: record.source_revision,
      source_revision_sequence: record.source_revision_sequence, content_connection_id: @connection.id,
      bridge_record_id: record.id, content_binding_id: binding.id, binding_public_id: binding.public_id, restorable: true)
    source_state, record_state, binding_state = first_post.reload.attributes, record.reload.attributes, binding.reload.attributes
    original = notice.attributes
    replay = DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
    expect(replay.id).to eq(notice.id)
    expect(replay.attributes).to eq(original)
    expect(DiscussionBridgeSourceRevocation.count).to eq(1)
    expect(first_post.reload.attributes).to eq(source_state)
    expect(record.reload.attributes).to eq(record_state)
    expect(binding.reload.attributes).to eq(binding_state)
    expect(topic.reload.deleted_at).to be_nil
    expect { notice.update!(reason: "operator_hold") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "exposes only retained withdrawal identity after the source becomes private" do
    topic, first_post, record, binding = publication
    expect_enqueued_with(job: :discussion_bridge_record_source_revocations,
      args: { category_id: category.id, cut: binding.id, position: 0 }) do
      category.update!(permissions: { "staff" => 1 })
    end
    expect(Guardian.new.can_see?(topic.reload)).to eq(false)
    notice = DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
    expect(notice.reason).to eq("source_unpublished")
    value = request_notices({}, resource_id: record.resource_id, name: "revocation-private-detail.json")
    expect(response).to have_http_status(:ok), response.body
    expect(value).to include("revocation_id" => notice.public_id, "reason" => "source_unpublished",
      "affected_binding_ids" => [binding.public_id], "source_revision" => record.source_revision)
    expect(value.keys.sort).to eq(%w[affected_binding_ids correlation_id effective_at policy_revision reason resource_id
      restorable revocation_id source_revision source_revision_sequence].sort)
    expect(response.body).not_to include(first_post.cooked, topic.title, binding.canonical_url)
  end

  it "retains a connection-owned notice when origin scope is removed" do
    _topic, _first_post, record, binding = publication
    @connection.update!(allowed_origins: ["https://other.example"])
    notice = DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
    expect(notice.reason).to eq("scope_removed")
    value = request_notices({}, resource_id: record.resource_id, name: "revocation-scope-detail.json")
    expect(response).to have_http_status(:ok), response.body
    expect(value.fetch("revocation_id")).to eq(notice.public_id)
  end

  it "does not infer withdrawal from an ordinary edit or listed/unlisted change" do
    topic, first_post, _record, binding = publication
    topic.update!(visible: false)
    PostRevisor.new(first_post).revise!(admin, { raw: "A legitimate source update." }, force_new_version: true)
    expect(DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)).to be_nil
    expect(DiscussionBridgeSourceRevocation.count).to eq(0)
  end

  it "pins a finite high-water window and excludes notices recorded later" do
    first, = withdraw
    second, = withdraw
    initial = request_notices({ limit: 1 }, name: "revocations-first.json")
    expect(initial.fetch("items").sole.fetch("revocation_id")).to eq(first.public_id)
    expect(initial.fetch("complete")).to eq(false)
    window = DiscussionBridgeSourceRevocationWindow.find_by!(public_id: initial.fetch("high_water"))
    cut = window.revocation_cut
    later, = withdraw
    last = resume(initial, name: "revocations-pinned-last.json")
    expect(response).to have_http_status(:ok), response.body
    expect(last).to include("high_water" => initial.fetch("high_water"), "policy_revision" => initial.fetch("policy_revision"),
      "complete" => true, "next_cursor" => nil)
    expect(last.fetch("items").sole.fetch("revocation_id")).to eq(second.public_id)
    expect(window.reload.revocation_cut).to eq(cut)
    expect(request_notices.fetch("items").map { |item| item.fetch("revocation_id") }).to include(later.public_id)
  end

  it "replays through fresh readers without acknowledging delivery or changing notice bytes" do
    first, _topic, first_post, record, binding = withdraw
    withdraw
    initial = request_notices(limit: 1)
    states = [first.attributes, first_post.reload.attributes, record.reload.attributes, binding.reload.attributes, @connection.reload.attributes]
    last = resume(initial, name: "revocations-resumed.json")
    expect(resume(initial, name: "revocations-replayed.json")).to eq(last)
    expect([first.reload.attributes, first_post.reload.attributes, record.reload.attributes,
      binding.reload.attributes, @connection.reload.attributes]).to eq(states)
    expect(DiscussionBridgeSourceRevocation.count).to eq(2)
  end

  it "keeps an initially empty cut empty through later notices" do
    empty = request_notices
    withdraw
    expect(request_notices(high_water: empty.fetch("high_water"))).to eq(empty)
    expect(request_notices.fetch("items").length).to eq(1)
  end

  it "retains unacknowledged notices beyond 90 days while expiring inactive cursors separately" do
    notice, = withdraw
    withdraw
    initial = request_notices(limit: 1)
    window = DiscussionBridgeSourceRevocationWindow.find_by!(public_id: initial.fetch("high_water"))
    window.update!(last_read_at: Time.now.utc - 91.days)
    window_before = window.reload.attributes
    notice_before = notice.reload.attributes
    resume(initial, name: "revocations-expired.json")
    expect_error("snapshot_expired", 410)
    expect(window.reload.attributes).to eq(window_before)
    freeze_time 91.days.from_now do
      current = request_notices({}, name: "revocations-retained.json")
      expect(response).to have_http_status(:ok), response.body
      expect(current.fetch("items").map { |item| item.fetch("revocation_id") }).to include(notice.public_id)
      expect(notice.reload.attributes).to eq(notice_before)
    end
  end

  it "extends window activity only on a successful read" do
    withdraw
    initial = request_notices
    window = DiscussionBridgeSourceRevocationWindow.find_by!(public_id: initial.fetch("high_water"))
    established = window.established_at
    freeze_time 29.days.from_now do
      request_notices(high_water: initial.fetch("high_water"))
      expect(response).to have_http_status(:ok), response.body
      expect(window.reload.last_read_at).to eq_time(Time.now.utc)
      expect(window.established_at).to eq_time(established)
    end
  end

  it "rejects changed policy and missing pinned context rather than continuing silently" do
    withdraw
    withdraw
    initial = request_notices(limit: 1)
    @connection.update!(allowed_origins: ["https://native.example", "https://other.example"])
    resume(initial, name: "revocations-policy-mismatch.json")
    expect_error("cursor_snapshot_mismatch", 409)
    request_notices(cursor: initial.fetch("next_cursor"))
    expect_error("cursor_snapshot_mismatch", 409)
  end

  it "isolates notice detail and signed cursors between authenticated connections" do
    notice, = withdraw
    withdraw
    initial = request_notices(limit: 1)
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Other notices", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    resume(initial, name: "revocations-connection-mismatch.json")
    expect_error("cursor_snapshot_mismatch", 409)
    request_notices({}, resource_id: notice.resource_id, name: "revocation-other-connection.json")
    expect_error("not_found", 404)
    expect(request_notices.fetch("items")).to eq([])
  end

  it "rejects malformed query values, extra fields and tampered cursors" do
    [ { limit: "0" }, { limit: "101" }, { limit: "01" }, { limit: [1] },
      { high_water: "unissued" }, { cursor: "tampered" } ].each do |query|
      request_notices(query)
      expect_error("validation_failed", 422)
    end
    request_notices({ acknowledge: "true" }, name: "revocations-unknown-field.json")
    expect_error("unknown_field", 400)
    expect(DiscussionBridgeSourceRevocationWindow.count).to eq(0)
  end

  it "fails closed on tampered retained source context without fabricating a notice" do
    _topic, first_post, record, binding = publication
    record.update_columns(source_revision: "fabricated-revision")
    first_post.update_columns(deleted_at: Time.now.utc)
    expect { DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id) }
      .to raise_error(ArgumentError, "source withdrawal revision requires reconciliation")
    expect(DiscussionBridgeSourceRevocation.count).to eq(0)
  end

  it "rejects a tampered notice without refreshing window activity or publication state" do
    notice, _topic, _first_post, record, = withdraw
    initial = request_notices
    window = DiscussionBridgeSourceRevocationWindow.find_by!(public_id: initial.fetch("high_water"))
    before = window.attributes
    DiscussionBridgeSourceRevocation.where(id: notice.id).update_all(reason: "operator_hold")
    request_notices({ high_water: initial.fetch("high_water") }, name: "revocations-integrity-error.json")
    expect_error("reconciliation_required", 409)
    expect(window.reload.attributes).to eq(before)
    expect(record.reload.state).to eq("healthy")
  end

  it "does not select native retained content into Ruby when reading withdrawal notices" do
    notice, = withdraw
    queries = []
    callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      request_notices({}, resource_id: notice.resource_id, name: "revocation-deleted-detail.json")
    end
    expect(response).to have_http_status(:ok), response.body
    retained_queries = queries.select { |sql| sql.include?("discussion_bridge_native_source_revisions") }
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, "revocation-read-sql.json"), retained_queries.to_json) if directory
    expect(retained_queries).not_to be_empty
    projection = %w[bridge_record_id revision sequence].map { |name| "\"discussion_bridge_native_source_revisions\".\"#{name}\"" }.join(", ")
    expect(retained_queries.all? { |sql| sql.partition(/\sFROM\s/i).first == "SELECT #{projection}" }).to eq(true), retained_queries.join("\n")
  end

  it "preserves notices when an affected binding becomes historical" do
    notice, _topic, _first_post, _record, binding = withdraw
    binding.update!(state: "historical", retired_at: Time.now.utc)
    value = request_notices({}, resource_id: notice.resource_id)
    expect(response).to have_http_status(:ok), response.body
    expect(value.fetch("affected_binding_ids")).to eq([binding.public_id])
  end

  it "protects referenced revisions and refuses populated schema rollback" do
    notice, = withdraw
    expect do
      DiscussionBridgeNativeSourceRevision.transaction(requires_new: true) do
        DiscussionBridgeNativeSourceRevision.where(id: notice.native_source_revision_id).delete_all
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    expect(DiscussionBridgeNativeSourceRevision.exists?(notice.native_source_revision_id)).to eq(true)
    migration = File.join(Rails.root, "plugins/discourse-discussion-bridge/db/migrate/20261007000001_retain_reconciled_source_revocations.rb")
    require migration
    expect { RetainReconciledSourceRevocations.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(DiscussionBridgeSourceRevocation.count).to eq(1)
  end

  it "queues a native first-post deletion and records it through the real worker" do
    topic, first_post, _record, binding = publication
    expect_enqueued_with(job: :discussion_bridge_record_source_revocations, args: { topic_id: topic.id, cut: binding.id, position: 0 }) do
      PostDestroyer.new(admin, first_post).destroy
    end
    Jobs::DiscussionBridgeRecordSourceRevocations.new.execute(topic_id: topic.id, cut: binding.id, position: 0)
    expect(DiscussionBridgeSourceRevocation.sole.reason).to eq("source_deleted")
    Jobs::DiscussionBridgeRecordSourceRevocations.new.execute(topic_id: topic.id, cut: binding.id, position: 0)
    expect(DiscussionBridgeSourceRevocation.count).to eq(1)
  end

  it "queues connection scope changes while unrelated or disabled forums remain inert" do
    topic, _first_post, _record, binding = publication
    expect_enqueued_with(job: :discussion_bridge_record_source_revocations,
      args: { content_connection_id: @connection.id, cut: binding.id, position: 0 }) do
      @connection.update!(allowed_origins: ["https://other.example"])
    end
    Jobs::DiscussionBridgeRecordSourceRevocations.new.execute(content_connection_id: @connection.id, cut: binding.id, position: 0)
    expect(DiscussionBridgeSourceRevocation.sole.reason).to eq("scope_removed")
    unrelated = Fabricate(:topic, user: admin, category: category)
    expect_not_enqueued_with(job: :discussion_bridge_record_source_revocations) do
      DiscussionBridge::SourceRevocationProducer.enqueue("topic_id" => unrelated.id)
    end
    SiteSetting.discussion_bridge_publisher_enabled = false
    expect_not_enqueued_with(job: :discussion_bridge_record_source_revocations) do
      DiscussionBridge::SourceRevocationProducer.enqueue("topic_id" => topic.id)
    end
  end

  it "bounds native worker batches and advances a real fixed binding cut" do
    _first_topic, _first_post, _first_record, first_binding = publication
    _last_topic, _last_post, _last_record, last_binding = publication
    @connection.update!(allowed_origins: ["https://other.example"])
    stub_const(DiscussionBridge::SourceRevocationProducer, :BATCH_SIZE, 1) do
      expect_enqueued_with(job: :discussion_bridge_record_source_revocations,
        args: { content_connection_id: @connection.id, cut: last_binding.id, position: first_binding.id }) do
        Jobs::DiscussionBridgeRecordSourceRevocations.new.execute(content_connection_id: @connection.id, cut: last_binding.id, position: 0)
      end
      expect(DiscussionBridgeSourceRevocation.count).to eq(1)
      Jobs::DiscussionBridgeRecordSourceRevocations.new.execute(content_connection_id: @connection.id, cut: last_binding.id, position: first_binding.id)
      expect(DiscussionBridgeSourceRevocation.count).to eq(2)
    end
  end

  it "rechecks delayed workers without withdrawing a now-eligible source" do
    _topic, first_post, _record, binding = publication
    first_post.update_columns(deleted_at: Time.now.utc)
    first_post.update_columns(deleted_at: nil)
    Jobs::DiscussionBridgeRecordSourceRevocations.new.execute(content_connection_id: @connection.id, cut: binding.id, position: 0)
    expect(DiscussionBridgeSourceRevocation.count).to eq(0)
  end

  it "does not skip a notice when the serialized page budget ends before its scan limit" do
    expected = 3.times.map { withdraw.first.public_id }
    stub_const(DiscussionBridge::SourceRevocations, :MAX_RESPONSE_BYTES, 9000) do
      page = request_notices(limit: 3)
      expect(response).to have_http_status(:ok), response.body
      expect(page.fetch("complete")).to eq(false)
      actual = page.fetch("items").map { |item| item.fetch("revocation_id") }
      3.times do
        break if page.fetch("complete")
        page = resume(page)
        expect(response).to have_http_status(:ok), response.body
        expect(response.body.bytesize).to be <= 9000
        actual.concat(page.fetch("items").map { |item| item.fetch("revocation_id") })
      end
      expect(page.fetch("complete")).to eq(true)
      expect(page.fetch("next_cursor")).to be_nil
      expect(actual).to eq(expected)
    end
  end
end
