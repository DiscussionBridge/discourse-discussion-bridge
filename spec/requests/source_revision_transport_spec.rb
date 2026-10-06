# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge exact source revision transport" do
  fab!(:admin)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, user: admin, category: category) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "An exact source article.") }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Source transport",
      platform: "ghost", allowed_origins: ["https://native.example"],
      allowed_directions: ["from_discourse"], allowed_lanes: [])
  end

  def publish(external_id: "article:1", canonical_url: "https://native.example/article/")
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: {
      content_connection_id: @connection.id, external_id: external_id, canonical_url: canonical_url,
      presentation_mode: "interactive",
    } }, as: :json
    expect(response).to have_http_status(:created).or have_http_status(:ok)
    @record = DiscussionBridgeBridgeRecord.where(topic_id: topic.id).order(:id).last
    sign_out
  end

  def read(revision: @record.source_revision, chunk: nil, extra: {}, name: nil, topic_id: topic.id)
    headers = { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
                "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "source-transport",
                "HTTPS" => "on" }
    path = "/discussion-bridge/v1/source-topics/#{topic_id}#{chunk.nil? ? '' : '/content'}.json"
    query = { source_revision: revision }.merge(extra)
    query[:chunk] = chunk unless chunk.nil?
    get path, params: query, headers: headers
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, name), response.body) if directory && name
    response.parsed_body
  end

  def expect_error(code, status)
    expect(response).to have_http_status(status), response.body
    expect(response.parsed_body.fetch("error_code")).to eq(code)
    expect(response.parsed_body.fetch("correlation_id")).to eq("source-transport")
    expect(response.headers["X-DiscussionBridge-Correlation"]).to eq("source-transport")
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
  end

  it "returns real retained metadata and whole inline content without source, binding or presence writes" do
    publish
    topic_state = topic.reload.attributes
    post_state = first_post.reload.attributes
    record_state = @record.reload.attributes
    binding_state = @record.active_binding("presentation").attributes
    connection_state = @connection.reload.attributes
    value = read(name: "source-inline.json")
    expect(response).to have_http_status(:ok), response.body
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
    expect(response.headers["X-DiscussionBridge-Correlation"]).to eq(value.fetch("correlation_id"))
    expect(value).to include("resource_id" => @record.resource_id, "topic_id" => topic.id,
      "title" => topic.title, "presentation_mode" => "interactive", "content_disposition" => "complete",
      "network_provenance" => nil, "source_updated_at" => first_post.updated_at.utc.iso8601(6))
    expect(value.fetch("source_authors").sole).to include("source_author_id" => "discourse:user:#{admin.id}",
      "source_author_name" => admin.username, "source_author_url" => "#{Discourse.base_url}/u/#{admin.username}")
    expect(value.fetch("categories").sole).to include("source_category_id" => "discourse:category:#{category.id}",
      "source_category_name" => category.name, "source_parent_category_id" => nil)
    expect(value.fetch("content_transport")).to include("mode" => "inline", "content_html" => first_post.cooked,
      "byte_length" => first_post.cooked.bytesize, "sha256" => Digest::SHA256.hexdigest(first_post.cooked))
    retained = @record.native_source_revisions.sole.reload
    expect(DiscussionBridge::NativeSourceRevisionCapture.fingerprint(retained.metadata)).to eq(retained.fingerprint)
    expect(topic.reload.attributes).to eq(topic_state)
    expect(first_post.reload.attributes).to eq(post_state)
    expect(@record.reload.attributes).to eq(record_state)
    expect(@record.active_binding("presentation").attributes).to eq(binding_state)
    expect(@connection.reload.attributes).to eq(connection_state)
  end

  it "delivers a large rich UTF-8 source as bounded byte slices, even across UTF-8 character boundaries" do
    html = "<p>#{'ü数学🚀' * 20_000}</p><pre><code>mermaid\nflowchart TD\nA --&gt; B</code></pre><table><tr><td>1</td></tr></table>"
    first_post.update_columns(cooked: html)
    publish
    value = read(name: "source-chunked.json")
    expect(response).to have_http_status(:ok), response.body
    descriptor = value.fetch("content_transport")
    expect(descriptor).to include("mode" => "chunked", "byte_length" => html.bytesize,
      "sha256" => Digest::SHA256.hexdigest(html), "decoded_chunk_maximum_bytes" => 32_768)
    expect(descriptor.fetch("chunk_count")).to eq((html.bytesize + 32_767) / 32_768)
    expect(response.body.bytesize).to be < 4096
    parts = (1..descriptor.fetch("chunk_count")).map do |number|
      result = read(chunk: number, name: "source-chunk-#{number}.json")
      expect(response).to have_http_status(:ok), response.body
      expect(response.body.bytesize).to be < 65_536
      expect(result.fetch("decoded_bytes")).to be_between(1, 32_768)
      bytes = Base64.strict_decode64(result.fetch("content_base64"))
      expect(bytes.bytesize).to eq(result.fetch("decoded_bytes"))
      expect(Digest::SHA256.hexdigest(bytes)).to eq(result.fetch("chunk_sha256"))
      bytes
    end
    expect(parts.join.force_encoding(Encoding::UTF_8)).to eq(html)
    expect(@record.native_source_revisions.count).to eq(1)
  end

  it "uses chunked transport when JSON escaping exceeds the bound despite an inline-sized source" do
    first_post.update_columns(cooked: "<p>#{"\u0001" * 49_145}</p>")
    publish
    value = read(name: "source-escaped-descriptor.json")
    expect(response).to have_http_status(:ok), response.body
    expect(@record.source_content_bytes).to eq(49_152)
    expect(value.fetch("content_transport").fetch("mode")).to eq("chunked")
    expect(response.body.bytesize).to be < 262_144
  end

  it "supports an empty retained body with exactly one zero-byte chunk" do
    first_post.update_columns(cooked: "")
    publish
    value = read(chunk: 1, name: "source-empty-chunk.json")
    expect(response).to have_http_status(:ok), response.body
    expect(value).to include("chunk" => 1, "chunk_count" => 1, "decoded_bytes" => 0,
      "content_base64" => "", "chunk_sha256" => Digest::SHA256.hexdigest(""))
  end

  it "returns the requested old revision and retained descriptions after later edits or renames" do
    publish
    revision = @record.source_revision
    original = read
    category.update!(name: "New category name")
    PostRevisor.new(first_post).revise!(admin, { raw: "A later wiki revision." }, force_new_version: true)
    publish
    expect(@record.source_revision).not_to eq(revision)
    old = read(revision: revision, name: "source-old-revision.json")
    expect(response).to have_http_status(:ok), response.body
    expect(old).to eq(original)
    current = read
    expect(current.fetch("categories").sole.fetch("source_category_name")).to eq("New category name")
    expect(current.dig("content_transport", "content_html")).to include("later wiki revision")
  end

  it "does not substitute current cooked content or recapture on a read" do
    publish
    original = @record.native_source_revisions.sole.content_html
    first_post.update_columns(cooked: "<p>Uncaptured later source.</p>")
    value = read
    expect(response).to have_http_status(:ok), response.body
    expect(value.dig("content_transport", "content_html")).to eq(original)
    expect(@record.native_source_revisions.count).to eq(1)
  end

  it "fails closed for old captures without descriptive context rather than manufacturing metadata" do
    publish
    capture = @record.native_source_revisions.sole
    metadata = capture.metadata.except("source_authors", "categories", "tags", "topic_url")
    fingerprint = Digest::SHA256.hexdigest(JSON.generate(metadata.sort.to_h))
    DiscussionBridgeNativeSourceRevision.where(id: capture.id).update_all(metadata: metadata, fingerprint: fingerprint)
    @record.update_columns(source_request_fingerprint: fingerprint)
    read(name: "source-unknown-context.json")
    expect_error("reconciliation_required", :conflict)
    expect(@record.native_source_revisions.count).to eq(1)
  end

  it "rejects tampered retained bytes or metadata before emitting a descriptor" do
    publish
    capture = @record.native_source_revisions.sole
    DiscussionBridgeNativeSourceRevision.where(id: capture.id).update_all(content_html: "<p>Tampered</p>")
    read(name: "source-integrity-error.json")
    expect_error("integrity_failed", :unprocessable_entity)
    DiscussionBridgeNativeSourceRevision.where(id: capture.id).update_all(content_html: first_post.cooked,
      metadata: capture.metadata.merge("title" => "Changed retained title"))
    read
    expect_error("reconciliation_required", :conflict)
  end

  it "rechecks current anonymous visibility for every detail and chunk" do
    publish
    read
    expect(response).to have_http_status(:ok)
    category.update!(read_restricted: true)
    presence = @connection.reload.attributes
    read(name: "source-private-error.json")
    expect_error("policy_denied", :forbidden)
    read(chunk: 1)
    expect_error("policy_denied", :forbidden)
    expect(@connection.reload.attributes).to eq(presence)
  end

  it "rejects deletion and private-message conversion without deleting retained history" do
    publish
    first_post.update_columns(deleted_at: Time.zone.now)
    read
    expect_error("policy_denied", :forbidden)
    first_post.update_columns(deleted_at: nil)
    topic.update_columns(archetype: Archetype.private_message, category_id: nil)
    read
    expect_error("policy_denied", :forbidden)
    expect(@record.native_source_revisions.count).to eq(1)
  end

  it "never authorizes a different connection from the topic ID or descriptive adapter headers" do
    publish
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Other source", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    read(name: "source-other-connection-error.json")
    expect_error("not_found", :not_found)
    expect(@connection.reload.last_seen_at).to be_nil
  end

  it "rechecks direction, lane and origin without widening connection scope" do
    publish
    @connection.update!(allowed_directions: ["to_discourse"])
    read
    expect_error("direction_denied", :forbidden)
    @connection.update!(allowed_directions: ["from_discourse"], allowed_lanes: ["explicit"])
    read
    expect_error("scope_denied", :forbidden)
    @connection.update!(allowed_lanes: [], allowed_origins: ["https://different.example"])
    read
    expect_error("scope_denied", :forbidden)
  end

  it "rejects ambiguous same-topic records instead of taking an arbitrary first presentation" do
    publish
    publish(external_id: "article:2", canonical_url: "https://native.example/second/")
    expect(DiscussionBridgeBridgeRecord.where(topic_id: topic.id).count).to eq(2)
    read
    expect_error("reconciliation_required", :conflict)
  end

  it "rejects retargeted native topic context instead of publishing another topic's retained body" do
    publish
    other = Fabricate(:topic, user: admin, category: category)
    Fabricate(:post, topic: other, user: admin, post_number: 1)
    @record.update_columns(topic_id: other.id)
    read(topic_id: other.id)
    expect_error("reconciliation_required", :conflict)
  end

  it "rejects invalid, missing, unknown and over-bound revisions or chunk numbers" do
    publish
    read(revision: "unknown", name: "source-revision-not-found.json")
    expect_error("revision_not_found", :not_found)
    [nil, "", "x" * 256].each do |revision|
      read(revision: revision)
      expect_error("validation_failed", :unprocessable_entity)
    end
    %w[0 -1 01 1.5 2 9007199254740992].each do |chunk|
      read(chunk: chunk)
      expect_error("validation_failed", :unprocessable_entity)
    end
    read(extra: { unknown: "value" })
    expect_error("unknown_field", :bad_request)
    read(extra: { source_revision: [@record.source_revision] })
    expect_error("validation_failed", :unprocessable_entity)
    ["0", "01", "#{topic.id}suffix", "9007199254740992"].each do |topic_id|
      read(topic_id: topic_id)
      expect_error("validation_failed", :unprocessable_entity)
    end
  end

  it "rejects a rotated secret or disabled plugin without source or presence mutation" do
    publish
    @connection.rotate_secret!
    state = @connection.reload.attributes
    read
    expect_error("authentication_failed", :unauthorized)
    expect(@connection.reload.attributes).to eq(state)
    @secret = @connection.rotate_secret!
    SiteSetting.discussion_bridge_enabled = false
    read
    expect_error("temporarily_unavailable", :service_unavailable)
    expect(@record.native_source_revisions.count).to eq(1)
  end
end
