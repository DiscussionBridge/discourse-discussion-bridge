# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge native publication revision context" do
  fab!(:admin)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, user: admin, category: category) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "A durable native article.") }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Native source",
      platform: "ghost", allowed_origins: ["https://native.example"],
      allowed_directions: ["from_discourse"], allowed_lanes: [])
  end

  def publish(**changes)
    sign_in(admin)
    input = { content_connection_id: @connection.id, external_id: "article:1",
              canonical_url: "https://native.example/article/", presentation_mode: "interactive" }.merge(changes)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: input }, as: :json
  end

  def record
    DiscussionBridgeBridgeRecord.find_by!(direction: "from_discourse", topic_id: topic.id)
  end

  def read(name = nil, index: false)
    sign_out
    headers = { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
                "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "native-read",
                "HTTPS" => "on" }
    path = index ? "/discussion-bridge/v1/bridge-records.json" : "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json"
    get path, headers: headers
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, name), response.body) if directory && name
  end

  it "captures the exact whole cooked post and native clocks without editing the source or inventing publication success" do
    topic_attributes = topic.reload.attributes
    post_attributes = first_post.reload.attributes
    versions = PostRevision.where(post_id: first_post.id).count
    publish
    expect(response).to have_http_status(:created), response.body
    expect(topic.reload.attributes).to eq(topic_attributes)
    expect(first_post.reload.attributes).to eq(post_attributes)
    expect(PostRevision.where(post_id: first_post.id).count).to eq(versions)
    capture = record.native_source_revisions.sole
    expect(capture.content_html).to eq(first_post.cooked)
    expect(record).to have_attributes(source_created_at_raw: first_post.created_at.utc.iso8601(6),
      source_updated_at_raw: first_post.updated_at.utc.iso8601(6), source_context_state: "observed",
      source_content_bytes: first_post.cooked.bytesize, source_content_sha256: Digest::SHA256.hexdigest(first_post.cooked))
    read("native-record-show.json")
    expect(response).to have_http_status(:ok), response.body
    value = response.parsed_body.fetch("bridge_record")
    expect(value).to include("source_revision" => capture.revision, "source_revision_sequence" => 1)
    expect(value.fetch("bindings").sole.keys).not_to include("applied_source_revision", "publication_revision", "synchronized_at")
    read("native-record-index.json", index: true)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("records").sole.fetch("resource_id")).to eq(record.resource_id)
  end

  it "does not recapture on adapter reads or make duplicate captures on an exact staff replay" do
    publish
    ids = [record.id, record.resource_id, record.topic_id, record.active_binding("presentation").public_id]
    capture_attributes = record.native_source_revisions.sole.attributes
    publish
    expect(response).to have_http_status(:ok), response.body
    expect(record.native_source_revisions.sole.attributes).to eq(capture_attributes)
    read
    expect(response).to have_http_status(:ok), response.body
    expect([record.id, record.resource_id, record.topic_id, record.active_binding("presentation").public_id]).to eq(ids)
    expect(record.native_source_revisions.sole.attributes).to eq(capture_attributes)
  end

  it "retains distinct immutable revisions including a content revert without reusing the old sequence" do
    first_post.update!(wiki: true)
    publish
    original = record.native_source_revisions.sole
    original_attributes = original.attributes
    raw = first_post.raw
    revisor = PostRevisor.new(first_post)
    revisor.revise!(admin, { raw: "An updated durable native wiki article." }, force_new_version: true)
    publish
    expect(response).to have_http_status(:ok), response.body
    second = record.native_source_revisions.order(:sequence).last
    expect(second.sequence).to eq(2)
    expect(second.content_html).to include("updated durable native wiki")
    revisor = PostRevisor.new(first_post.reload)
    revisor.revise!(admin, { raw: raw }, force_new_version: true)
    publish
    expect(response).to have_http_status(:ok), response.body
    expect(record.source_revision_sequence).to eq(3)
    expect(record.native_source_revisions.pluck(:revision).uniq.size).to eq(3)
    expect(original.reload.attributes).to eq(original_attributes)
    expect(first_post.reload.wiki).to eq(true)
    expect { original.update!(content_html: "replacement") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "retains sources larger than the inline transport ceiling without truncating or raising a universal source cap" do
    html = "<p>#{'Large native article. ' * 20_000}</p>"
    first_post.update_columns(cooked: html)
    publish
    expect(response).to have_http_status(:created), response.body
    expect(record.native_source_revisions.sole.content_html).to eq(html)
    expect(record.source_content_bytes).to eq(html.bytesize)
    read
    expect(response).to have_http_status(:ok), response.body
    expect(response.body.bytesize).to be < 4096
    expect(response.parsed_body.fetch("bridge_record").fetch("content_disposition")).to eq("complete")
  end

  it "does not fabricate metadata for a historical publication whose context has been lost" do
    publish
    record.update_columns(source_revision: nil, source_context_state: nil)
    previous = record.attributes
    presence = @connection.reload.attributes
    read("native-unknown-context.json")
    expect(response).to have_http_status(:conflict), response.body
    expect(response.parsed_body.fetch("error_code")).to eq("reconciliation_required")
    expect(record.attributes).to eq(previous)
    expect(@connection.reload.attributes).to eq(presence)
    publish
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(record.attributes).to eq(previous)
    expect(record.native_source_revisions.count).to eq(1)
  end

  it "refuses tampered context without treating healthy state as proof" do
    publish
    record.update_columns(source_content_sha256: "0" * 64)
    read
    expect(response).to have_http_status(:conflict), response.body
    publish
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(record.native_source_revisions.count).to eq(1)
  end

  it "rechecks current anonymous visibility and leaves rejected-read presence unchanged" do
    publish
    category.update!(read_restricted: true)
    presence = @connection.reload.attributes
    read("native-private-context.json")
    expect(response).to have_http_status(:forbidden), response.body
    expect(response.parsed_body.fetch("error_code")).to eq("policy_denied")
    expect(@connection.reload.attributes).to eq(presence)
  end

  it "rolls back initial record and binding creation for a private native source" do
    category.update!(read_restricted: true)
    publish
    expect(response).to have_http_status(:forbidden), response.body
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeContentBinding.count).to eq(0)
    expect(DiscussionBridgeNativeSourceRevision.count).to eq(0)
  end

  it "rejects removed or malformed presentation modes without any capture" do
    %w[fullInteractive Interactive invalid].each do |mode|
      publish(presentation_mode: mode)
      expect(response).to have_http_status(:unprocessable_entity), response.body
    end
    expect(DiscussionBridgeNativeSourceRevision.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "rolls back the capture when binding creation fails" do
    DiscussionBridgeContentBinding.stubs(:create!).raises(ArgumentError, "binding rejected")
    publish
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(DiscussionBridgeNativeSourceRevision.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "bounds collision retries to one re-read and leaves no partial publication" do
    DiscussionBridgeContentBinding.stubs(:create!).twice.raises(ActiveRecord::RecordNotUnique)
    publish
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.fetch("errors")).to include("binding identity conflict")
    expect(DiscussionBridgeNativeSourceRevision.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "refuses rolling back the new table after retaining a source revision" do
    publish
    require_relative "../../db/migrate/20261006000002_retain_reconciled_native_source_revisions"
    expect { RetainReconciledNativeSourceRevisions.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(record.native_source_revisions.count).to eq(1)
  end

  it "preserves From source identity and capture history across migration without copying an unearned destination receipt" do
    publish
    original = record.active_binding("presentation")
    capture = record.native_source_revisions.sole.attributes
    resource_id = record.resource_id
    target, target_secret = DiscussionBridgeContentConnection.issue!(name: "New native destination", platform: "astro",
      allowed_origins: ["https://new-native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    sign_in(admin)
    post "/discussion-bridge/admin/bridge-records/#{record.id}/migrations.json", params: { migration: {
      content_connection_id: target.id, external_id: "astro:article", canonical_url: "https://new-native.example/article/",
    } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    prepared_id = response.parsed_body.fetch("prepared_binding_id")
    post "/discussion-bridge/admin/bridge-records/#{record.id}/migrations/#{prepared_id}/apply.json", as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(original.reload.state).to eq("historical")
    expect(record.native_source_revisions.sole.attributes).to eq(capture)
    expect(record.resource_id).to eq(resource_id)
    expect(record.active_binding("presentation").public_id).not_to eq(original.public_id)
    expect(record.active_binding("presentation").attributes.slice("applied_source_revision", "publication_revision", "synchronized_at_raw").values).to eq([nil, nil, nil])
    read
    expect(response).to have_http_status(:not_found), response.body
    @connection, @secret = target, target_secret
    read("migrated-native-record-show.json")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("bridge_record")).to include("resource_id" => resource_id,
      "source_revision" => capture.fetch("revision"), "topic_id" => topic.id)
    expect(response.parsed_body.dig("bridge_record", "bindings", 0, "presentation_mode")).to eq("interactive")
  end

  it "rechecks missing context at migration apply and leaves both binding states unchanged on rejection" do
    publish
    original = record.active_binding("presentation")
    target, = DiscussionBridgeContentConnection.issue!(name: "Prepared destination", platform: "astro",
      allowed_origins: ["https://prepared.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    sign_in(admin)
    post "/discussion-bridge/admin/bridge-records/#{record.id}/migrations.json", params: { migration: {
      content_connection_id: target.id, external_id: "prepared:article", canonical_url: "https://prepared.example/article/",
    } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    prepared_id = response.parsed_body.fetch("prepared_binding_id")
    record.update_columns(source_revision: nil)
    post "/discussion-bridge/admin/bridge-records/#{record.id}/migrations/#{prepared_id}/apply.json", as: :json
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(original.reload.state).to eq("active")
    expect(record.content_bindings.find(prepared_id).state).to eq("prepared")
    expect(record.state).to eq("migration")
  end
end
