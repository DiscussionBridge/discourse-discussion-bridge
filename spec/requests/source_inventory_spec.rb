# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge pinned native source inventory" do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Pinned inventory", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
  end

  def article(text: "A complete native article.")
    topic = Fabricate(:topic, user: admin, category: category)
    first_post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: text)
    [topic, first_post]
  end

  def publish(topic, external_id: "article:#{topic.id}", url: "https://native.example/articles/#{topic.id}/")
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: {
      content_connection_id: @connection.id, external_id: external_id, canonical_url: url, presentation_mode: "interactive",
    } }, as: :json
    @publication_status = response.status
    @publication_body = response.body
    sign_out
    DiscussionBridgeBridgeRecord.where(topic_id: topic.id).order(:id).last
  end

  def inventory(query = {}, name: nil, **fields)
    query = query.merge(fields)
    get "/discussion-bridge/v1/source-topics.json", params: query, headers: {
      "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "inventory-test", "HTTPS" => "on",
    }
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, name), response.body) if directory && name
    response.parsed_body
  end

  def resume(value, limit: 1, name: nil)
    inventory({ snapshot: value.fetch("snapshot"), cursor: value.fetch("next_cursor"), limit: limit }, name: name)
  end

  def expect_error(code, status)
    expect(response).to have_http_status(status), response.body
    expect(response.parsed_body).to include("error_code" => code, "correlation_id" => "inventory-test")
    expect(response.headers["X-DiscussionBridge-Correlation"]).to eq("inventory-test")
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
  end

  it "returns a valid empty terminal snapshot without inventing source observations" do
    value = inventory({}, name: "inventory-empty.json")
    expect(response).to have_http_status(:ok), response.body
    expect(value).to include("items" => [], "complete" => true, "next_cursor" => nil)
    expect(value.fetch("snapshot")).to match(/\Adbs_[a-f0-9]{32}\z/)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(0)
  end

  it "observes explicit publication atomically and makes exact replays idempotent" do
    topic, first_post = article
    record = publish(topic)
    expect(@publication_status).to eq(201), @publication_body
    entry = DiscussionBridgeSourceInventoryEntry.sole
    expect(entry).to have_attributes(bridge_record_id: record.id, native_source_revision_id: record.native_source_revisions.sole.id,
      topic_id: topic.id, resource_id: record.resource_id, content_connection_id: @connection.id)
    source = first_post.reload.attributes
    publish(topic)
    expect(@publication_status).to eq(200), @publication_body
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(1)
    expect(DiscussionBridgeSourceInventoryEntry.sole.attributes).to eq(entry.attributes)
    expect(first_post.reload.attributes).to eq(source)
    expect { entry.update!(canonical_url: "https://native.example/changed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "does not leave an unobserved record or capture when the inventory observation fails" do
    topic, first_post = article
    source = first_post.reload.attributes
    allow(DiscussionBridgeSourceInventoryEntry).to receive(:create!).and_raise(ArgumentError, "Synthetic observation failure")
    publish(topic)
    expect(@publication_status).to eq(422), @publication_body
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeContentBinding.count).to eq(0)
    expect(DiscussionBridgeNativeSourceRevision.count).to eq(0)
    expect(first_post.reload.attributes).to eq(source)
  end

  it "keeps the initial revision cut through later revisions and new publications" do
    first_topic, = article
    second_topic, second_post = article(text: "Original second article.")
    first_record = publish(first_topic)
    second_record = publish(second_topic)
    original_revision = second_record.source_revision
    original_title = second_topic.title
    first_page = inventory({ limit: 1 }, name: "inventory-first.json")
    expect(response).to have_http_status(:ok), response.body
    expect(first_page.fetch("items").sole.fetch("resource_id")).to eq(first_record.resource_id)
    expect(first_page.fetch("complete")).to eq(false)
    snapshot = DiscussionBridgeSourceInventorySnapshot.find_by!(public_id: first_page.fetch("snapshot"))
    cut = snapshot.observation_cut
    PostRevisor.new(second_post).revise!(admin, { raw: "A later second revision." }, force_new_version: true)
    second_topic.update!(title: "A later second title")
    publish(second_topic)
    third_topic, = article
    publish(third_topic)

    second_page = resume(first_page, name: "inventory-pinned-last.json")
    expect(response).to have_http_status(:ok), response.body
    expect(second_page).to include("snapshot" => first_page.fetch("snapshot"), "policy_revision" => first_page.fetch("policy_revision"),
      "complete" => true, "next_cursor" => nil)
    expect(second_page.fetch("items").sole).to include("resource_id" => second_record.resource_id,
      "source_revision" => original_revision, "title" => original_title)
    expect(snapshot.reload.observation_cut).to eq(cut)
    expect(second_record.reload.source_revision).not_to eq(original_revision)
    current = inventory
    expect(current.fetch("items").map { |item| item.fetch("topic_id") }).to contain_exactly(first_topic.id, second_topic.id, third_topic.id)
    expect(current.fetch("items").find { |item| item.fetch("topic_id") == second_topic.id }.fetch("source_revision")).to eq(second_record.source_revision)
  end

  it "makes real progress on an empty nonterminal page containing a superseded observation" do
    topic, first_post = article
    record = publish(topic)
    PostRevisor.new(first_post).revise!(admin, { raw: "New revision before the cut." }, force_new_version: true)
    publish(topic)
    other_topic, = article
    publish(other_topic)
    first = inventory({ limit: 1 }, name: "inventory-empty-progress.json")
    expect(response).to have_http_status(:ok), response.body
    expect(first).to include("items" => [], "complete" => false)
    verifier = Rails.application.message_verifier(:discussion_bridge_source_inventory)
    token = verifier.verified(first.fetch("next_cursor"), purpose: DiscussionBridge::SourceInventory::CURSOR_PURPOSE)
    expect(token.fetch("position")).to eq(DiscussionBridgeSourceInventoryEntry.order(:id).first.id)
    second = resume(first)
    expect(second.fetch("items").sole.fetch("source_revision")).to eq(record.reload.source_revision)
    third = resume(second)
    expect(third).to include("complete" => true, "next_cursor" => nil)
    expect(third.fetch("items").sole.fetch("topic_id")).to eq(other_topic.id)
  end

  it "replays a cursor through fresh reader instances without duplicating observations or changing publication state" do
    topics = 2.times.map { article.first }
    records = topics.map { |topic| publish(topic) }
    first = inventory(limit: 1)
    record_states = records.map { |record| record.reload.attributes }
    binding_states = records.map { |record| record.active_binding("presentation").attributes }
    source_states = topics.map { |topic| topic.first_post.reload.attributes }
    connection_state = @connection.reload.attributes
    last = resume(first, name: "inventory-resumed.json")
    replay = resume(first, name: "inventory-replayed.json")
    expect(replay).to eq(last)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(2)
    expect(records.map { |record| record.reload.attributes }).to eq(record_states)
    expect(records.map { |record| record.active_binding("presentation").attributes }).to eq(binding_states)
    expect(topics.map { |topic| topic.first_post.reload.attributes }).to eq(source_states)
    expect(@connection.reload.attributes).to eq(connection_state)
  end

  it "rechecks privacy on every page and advances past newly private and deleted sources" do
    first_topic, = article
    second_topic, second_post = article
    publish(first_topic)
    publish(second_topic)
    first = inventory(limit: 1)
    second_post.update_columns(deleted_at: Time.now.utc)
    last = resume(first, name: "inventory-private-last.json")
    expect(response).to have_http_status(:ok), response.body
    expect(last).to include("items" => [], "complete" => true, "next_cursor" => nil)
    second_post.update_columns(deleted_at: nil)
    category.update!(read_restricted: true)
    value = inventory(limit: 1)
    expect(value).to include("items" => [], "complete" => false)
    value = resume(value)
    expect(value).to include("items" => [], "complete" => true, "next_cursor" => nil)
    expect(DiscussionBridgeNativeSourceRevision.count).to eq(2)
  end

  it "rejects changed policy context without refreshing activity or silently reopening the snapshot" do
    2.times { publish(article.first) }
    first = inventory(limit: 1)
    snapshot = DiscussionBridgeSourceInventorySnapshot.find_by!(public_id: first.fetch("snapshot"))
    state = snapshot.attributes
    @connection.update!(allowed_lanes: ["new-lane"])
    resume(first, name: "inventory-policy-mismatch.json")
    expect_error("cursor_snapshot_mismatch", :conflict)
    expect(snapshot.reload.attributes).to eq(state)
    expect(DiscussionBridgeSourceInventorySnapshot.count).to eq(1)
  end

  it "rejects cross-connection and altered cursors, missing snapshot context and unknown query fields" do
    2.times { publish(article.first) }
    first = inventory(limit: 1)
    inventory({ snapshot: first.fetch("snapshot"), cursor: first.fetch("next_cursor") + "x" })
    expect_error("validation_failed", :unprocessable_entity)
    inventory(cursor: first.fetch("next_cursor"))
    expect_error("cursor_snapshot_mismatch", :conflict)
    inventory({ snapshot: first.fetch("snapshot"), high_water: "undeclared" })
    expect_error("unknown_field", :bad_request)
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Other inventory", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    resume(first, name: "inventory-connection-mismatch.json")
    expect_error("cursor_snapshot_mismatch", :conflict)
    inventory(snapshot: first.fetch("snapshot"))
    expect_error("snapshot_expired", :gone)
    expect(DiscussionBridgeSourceInventorySnapshot.count).to eq(1)
  end

  it "expires inactive snapshots without deleting history or refreshing activity on failure" do
    publish(article.first)
    first = inventory
    snapshot = DiscussionBridgeSourceInventorySnapshot.find_by!(public_id: first.fetch("snapshot"))
    snapshot.update_columns(last_read_at: 31.days.ago)
    state = snapshot.reload.attributes
    inventory({ snapshot: first.fetch("snapshot") }, name: "inventory-expired.json")
    expect_error("snapshot_expired", :gone)
    expect(snapshot.reload.attributes).to eq(state)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(1)
    restarted = inventory
    expect(restarted.fetch("snapshot")).not_to eq(first.fetch("snapshot"))
    expect(restarted.fetch("items")).to eq(first.fetch("items"))
  end

  it "extends retention after a successful replay, rather than expiring from establishment" do
    publish(article.first)
    first = inventory
    snapshot = DiscussionBridgeSourceInventorySnapshot.find_by!(public_id: first.fetch("snapshot"))
    established_at = snapshot.established_at
    snapshot.update_columns(last_read_at: 29.days.ago)
    inventory(snapshot: first.fetch("snapshot"))
    expect(response).to have_http_status(:ok), response.body
    expect(snapshot.reload.last_read_at).to be > 1.minute.ago
    expect(snapshot.established_at).to eq_time(established_at)
  end

  it "does not guess an ambiguous topic binding or accept corrupted observed identity" do
    topic, = article
    publish(topic)
    entry = DiscussionBridgeSourceInventoryEntry.sole
    DiscussionBridgeSourceInventoryEntry.where(id: entry.id).update_all(resource_id: SecureRandom.uuid)
    inventory({}, name: "inventory-integrity-conflict.json")
    expect_error("reconciliation_required", :conflict)
    expect(DiscussionBridgeSourceInventorySnapshot.count).to eq(0)
    DiscussionBridgeSourceInventoryEntry.where(id: entry.id).update_all(resource_id: entry.resource_id)
    publish(topic, external_id: "other", url: "https://native.example/other/")
    inventory
    expect_error("reconciliation_required", :conflict)
  end

  it "rejects malformed limits, snapshots and cursor shapes without creating snapshots" do
    ["0", "01", "101", "-1", "1.5", ["1"]].each do |limit|
      inventory(limit: limit)
      expect_error("validation_failed", :unprocessable_entity)
    end
    ["", "bad", ["dbs_#{'1' * 32}"]].each do |snapshot|
      inventory(snapshot: snapshot)
      expect_error("validation_failed", :unprocessable_entity)
    end
    inventory(cursor: ["bad"])
    expect_error("validation_failed", :unprocessable_entity)
    expect(DiscussionBridgeSourceInventorySnapshot.count).to eq(0)
  end

  it "rechecks authentication and direction without creating snapshots or touching presence" do
    @connection.rotate_secret!
    inventory
    expect_error("authentication_failed", :unauthorized)
    @secret = @connection.rotate_secret!
    @connection.update!(allowed_directions: ["to_discourse"])
    inventory
    expect_error("direction_denied", :forbidden)
    @connection.update!(allowed_directions: ["from_discourse"])
    SiteSetting.discussion_bridge_enabled = false
    inventory
    expect_error("temporarily_unavailable", :service_unavailable)
    expect(DiscussionBridgeSourceInventorySnapshot.count).to eq(0)
    expect(@connection.reload.last_seen_at).to be_nil
  end

  it "refuses populated schema rollback and preserves observations and snapshots" do
    publish(article.first)
    inventory
    require_relative "../../db/migrate/20261006000003_retain_reconciled_source_inventory"
    expect { RetainReconciledSourceInventory.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(1)
    expect(DiscussionBridgeSourceInventorySnapshot.count).to eq(1)
  end

  it "keeps an established empty cut empty after the first later publication" do
    original = inventory
    publish(article.first)
    replay = inventory(snapshot: original.fetch("snapshot"))
    expect(replay).to eq(original)
    current = inventory
    expect(current.fetch("items").length).to eq(1)
  end

  it "cannot delete a retained revision referenced by inventory observations" do
    record = publish(article.first)
    inventory
    capture_id = record.native_source_revisions.sole.id
    expect do
      DiscussionBridgeNativeSourceRevision.transaction(requires_new: true) do
        DiscussionBridgeNativeSourceRevision.where(id: capture_id).delete_all
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    expect(DiscussionBridgeNativeSourceRevision.exists?(capture_id)).to eq(true)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(1)
  end

  it "does not lose an item when the serialized page budget ends before its scan limit" do
    topics = 3.times.map { article.first }
    topics.each { |topic| publish(topic) }
    stub_const(DiscussionBridge::SourceInventory, :MAX_RESPONSE_BYTES, 9000) do
      page = inventory(limit: 3)
      expect(response).to have_http_status(:ok), response.body
      expect(page.fetch("complete")).to eq(false)
      ids = page.fetch("items").map { |item| item.fetch("topic_id") }
      3.times do
        break if page.fetch("complete")
        page = resume(page, limit: 3)
        expect(response).to have_http_status(:ok), response.body
        expect(response.body.bytesize).to be <= 9000
        ids.concat(page.fetch("items").map { |item| item.fetch("topic_id") })
      end
      expect(page).to include("complete" => true, "next_cursor" => nil)
      expect(ids).to contain_exactly(*topics.map(&:id))
    end
  end

  it "checks native first-post identity without selecting the mutable first-post body into Ruby" do
    topic, = article
    publish(topic)
    queries = []
    capture = ->(*arguments) { queries << arguments.last.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { inventory }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("items").sole.fetch("topic_id")).to eq(topic.id)
    expect(queries.grep(/SELECT\s+"posts"\.\*\s+FROM/i)).to be_empty
  end
end
