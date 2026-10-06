# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge reconciled To-Discourse publications" do
  fab!(:actor, :admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = actor.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Reconciled WordPress", platform: "wordpress",
      allowed_origins: ["https://publisher.example"], allowed_directions: ["to_discourse"], allowed_lanes: [],
    )
  end

  def headers(correlation = "repair-1")
    { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => correlation,
      "HTTPS" => "on" }
  end

  def source(**changes)
    html = changes.fetch(:content_html, "<p>A source-owned article with durable discussion.</p>")
    {
      direction: "to_discourse", external_id: "post:stable-41",
      canonical_url: "https://publisher.example/articles/durable/", title: "A durable source publication",
      content_html: html, published: true, presentation_mode: "interactive",
      source_revision: "revision:1", source_revision_sequence: 1,
      source_created_at: "2026-09-01T12:00:00.123456789012Z",
      source_updated_at: "2026-10-01T12:00:00.123456789012Z", content_disposition: "complete",
      source_content_bytes: html.bytesize, source_content_sha256: Digest::SHA256.hexdigest(html),
      correlation_id: "repair-1",
    }.merge(changes)
  end

  def publish(data = source, extra_headers: {})
    post "/discussion-bridge/v1/bridge-records/resolve.json", params: { bridge_record: data },
         headers: headers(data[:correlation_id]).merge(extra_headers), as: :json
  end

  def record
    DiscussionBridgeBridgeRecord.find_by!(direction: "to_discourse")
  end

  def save_contract_response(name)
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, name), response.body) if directory
  end

  it "creates once, stores exact source clocks and resolves an exact replay without a native edit" do
    publish
    expect(response).to have_http_status(:created), response.body
    save_contract_response("created.json")
    first = response.parsed_body
    expect(first).to include("accepted_source_revision" => "revision:1", "accepted_source_revision_sequence" => 1,
                             "core_fallback" => false, "correlation_id" => "repair-1")
    ids = [record.id, record.resource_id, record.topic_id, record.topic.first_post.id, record.active_binding("source").id]
    expect(record.source_updated_at_raw).to eq(source[:source_updated_at])
    expect(record.source_created_at_raw).to eq(source[:source_created_at])
    version = record.topic.first_post.version
    publish(source(correlation_id: "different-attempt"))
    expect(response).to have_http_status(:ok), response.body
    save_contract_response("replayed.json")
    expect([record.id, record.resource_id, record.topic_id, record.topic.first_post.id, record.active_binding("source").id]).to eq(ids)
    expect(record.topic.first_post.version).to eq(version)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end

  it "applies an explicit new revision through native revision history without replacing any identity or replies" do
    publish
    original = record
    post_id = original.topic.first_post.id
    binding_id = original.active_binding("source").public_id
    reply = Fabricate(:post, topic: original.topic, user: actor, post_number: 2)
    post_version = original.topic.first_post.version
    revised = source(title: "The updated durable source publication", content_html: "<p>A revised authoritative article.</p>",
                     source_revision: "revision:2", source_revision_sequence: 2,
                     source_updated_at: "2026-10-02T12:00:00.123456789013Z")
    publish(revised)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("topic_id" => original.topic_id, "resource_id" => original.resource_id,
                                          "accepted_source_revision" => "revision:2")
    expect(original.reload.topic.first_post.id).to eq(post_id)
    expect(original.topic.reload.title).to eq(revised[:title])
    expect(original.topic.first_post.reload.raw).to include("revised authoritative article")
    expect(original.topic.first_post.version).to be > post_version
    expect(PostRevision.where(post_id: post_id)).to exist
    expect(reply.reload.topic_id).to eq(original.topic_id)
    expect(original.active_binding("source").public_id).to eq(binding_id)
    expect(original.source_updated_at_raw).to eq(revised[:source_updated_at])
  end

  it "uses the same source revision rules for a wiki first post" do
    publish
    record.topic.first_post.update!(wiki: true)
    publish(source(content_html: "<p>A corrected authoritative wiki article.</p>", source_revision: "wiki:2",
                   source_revision_sequence: 2, source_updated_at: "2026-10-03T00:00:00Z"))
    expect(response).to have_http_status(:ok), response.body
    expect(record.topic.first_post.reload.wiki).to eq(true)
    expect(record.topic.first_post.raw).to include("corrected authoritative wiki")
  end

  it "adopts an exact Core embed without changing title, post, owner, timestamps or revision trail" do
    topic = Fabricate(:topic, user: actor, category: category, visible: false, title: "Existing Core embed title")
    post = Fabricate(:post, topic: topic, user: actor, post_number: 1, raw: "Existing substantive first post")
    TopicEmbed.create!(topic_id: topic.id, post_id: post.id, embed_url: TopicEmbed.normalize_url(source[:canonical_url]))
    before_topic = topic.reload.attributes.slice("title", "user_id", "updated_at")
    before_post = post.reload.attributes.slice("id", "raw", "user_id", "updated_at", "version")
    revisions = PostRevision.where(post_id: post.id).count
    publish(source(existing_topic_id: topic.id))
    expect(response).to have_http_status(:created), response.body
    expect(record.topic_id).to eq(topic.id)
    expect(topic.reload.attributes.slice(*before_topic.keys)).to eq(before_topic)
    expect(post.reload.attributes.slice(*before_post.keys)).to eq(before_post)
    expect(PostRevision.where(post_id: post.id).count).to eq(revisions)
    expect(record.source_context_state).to eq("observed")
    expect(record.active_binding("source").applied_source_revision).to be_nil
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json", headers: headers
    expect(response).to have_http_status(:ok), response.body
    observed_binding = response.parsed_body.fetch("bridge_record").fetch("bindings").first
    expect(observed_binding.keys & %w[applied_source_revision publication_revision synchronized_at]).to be_empty
    save_contract_response("adopted-record-show.json")
    publish(source(existing_topic_id: topic.id))
    expect(response).to have_http_status(:ok), response.body
    expect(post.reload.raw).to eq(before_post["raw"])
    publish(source(existing_topic_id: topic.id, source_revision: "revision:2", source_revision_sequence: 2,
                   source_updated_at: "2026-10-03T00:00:00Z"))
    expect(response).to have_http_status(:ok), response.body
    expect(record.source_context_state).to eq("applied")
    expect(record.topic.first_post.id).to eq(post.id)
  end

  it "preserves unknown historical revision data and fails closed rather than using health as update permission" do
    publish
    old = record
    old.update_columns(source_revision: nil, source_revision_sequence: nil,
                       source_request_fingerprint: nil, source_context_state: nil)
    original_post = old.topic.first_post.attributes.slice("raw", "updated_at", "version")
    publish(source(source_revision: "revision:2", source_revision_sequence: 2))
    expect(response).to have_http_status(:conflict), response.body
    expect(response.parsed_body.fetch("reason")).to eq("source_revision_context_unknown")
    save_contract_response("unknown-context-conflict.json")
    expect(old.reload.source_revision).to be_nil
    expect(old.topic.first_post.reload.attributes.slice(*original_post.keys)).to eq(original_post)
  end

  it "rejects changed replay content, stale revisions, changed creation clocks and unverified URL changes without mutation" do
    publish
    saved = record.attributes
    original = record.topic.first_post.attributes.slice("raw", "updated_at", "version")
    invalid = [source(content_html: "<p>Different body at the same revision.</p>"),
               source(source_created_at: "2026-09-02T12:00:00Z"),
               source(canonical_url: "https://publisher.example/articles/renamed/"),
               source(source_revision: "revision:1", source_revision_sequence: 2)]
    invalid.each do |data|
      publish(data)
      expect(response).to have_http_status(:conflict), response.body
      expect(record.attributes).to eq(saved)
      expect(record.topic.first_post.reload.attributes.slice(*original.keys)).to eq(original)
    end
    publish(source(source_revision: "revision:2", source_revision_sequence: 2,
                   source_updated_at: "2026-10-02T00:00:00Z"))
    expect(response).to have_http_status(:ok), response.body
    publish
    expect(response).to have_http_status(:conflict), response.body
  end

  it "rolls back accepted metadata when native revision fails" do
    publish
    previous = record.attributes
    DiscussionBridge::TopicCreator.any_instance.stubs(:update).raises(
      DiscussionBridge::AdapterRequestBoundary::Error.new("content_unsupported"),
    )
    publish(source(source_revision: "revision:2", source_revision_sequence: 2))
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(record.attributes).to eq(previous)
  end

  it "keeps body bounds separate from the full source size and requires the exact safe Read More block" do
    html = '<p>Safe delivered content.</p><p>This is an excerpt.</p><p><a href="https://publisher.example/articles/durable/">Read More</a></p>'
    data = source(content_html: html, content_disposition: "excerpt", read_more_url: source[:canonical_url],
                  source_content_bytes: 9_007_199_254_740_991, source_content_sha256: "a" * 64)
    expect(DiscussionBridge::BridgeRecordRequest.call(data.deep_stringify_keys)[:content_disposition]).to eq("excerpt")
    publish(data)
    expect(response).to have_http_status(:created), response.body
    expect(record.source_content_bytes).to eq(9_007_199_254_740_991)
    expect(record.topic.first_post.raw).to include("This is an excerpt", "Read More")
  end

  it "respects the operator's native post limit and rolls back a rejected new publication" do
    SiteSetting.max_post_length = 500
    publish(source(content_html: "<p>#{'Bounded source content. ' * 40}</p>"))
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.fetch("error_code")).to eq("content_unsupported")
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeContentBinding.count).to eq(0)
    expect(@connection.reload.last_seen_at).to be_nil
  end

  it "preserves recorded context when the forward migration is asked to roll back" do
    publish
    expect(response).to have_http_status(:created), response.body
    require_relative "../../db/migrate/20261006000001_add_reconciled_to_discourse_revision_context"
    expect { AddReconciledToDiscourseRevisionContext.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(record.source_revision).to eq("revision:1")
    expect(record.active_binding("source").public_id).to be_present
  end

  it "rolls back native post-limit rejection of an explicit revision without advancing accepted source metadata" do
    publish
    expect(response).to have_http_status(:created), response.body
    previous_record = record.attributes
    previous_post = record.topic.first_post.reload.attributes.slice("raw", "version", "updated_at")
    SiteSetting.max_post_length = 500
    publish(source(content_html: "<p>#{'Too much revised content. ' * 40}</p>",
                   source_revision: "revision:2", source_revision_sequence: 2))
    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body.fetch("error_code")).to eq("content_unsupported")
    expect(record.attributes).to eq(previous_record)
    expect(record.topic.first_post.reload.attributes.slice(*previous_post.keys)).to eq(previous_post)
  end

  it "uses the bounded protocol envelope for an unexpected native failure without reflecting its details" do
    DiscussionBridge::BridgeRecordResolver.stubs(:call).raises(StandardError, "private upstream content and credential")
    publish
    expect(response).to have_http_status(:internal_server_error), response.body
    expect(response.parsed_body.keys).to contain_exactly("error_code", "message", "correlation_id")
    expect(response.parsed_body.fetch("error_code")).to eq("internal_error")
    expect(response.body).not_to include("private upstream", "credential")
    expect(response.body.bytesize).to be <= 4096
    expect(@connection.reload.last_seen_at).to be_nil
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "returns exact current record shapes and omits applied metadata for no-write adoption" do
    publish
    get "/discussion-bridge/v1/bridge-records.json", headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.keys).to contain_exactly("records", "page", "total_pages", "correlation_id")
    save_contract_response("records-index.json")
    binding = response.parsed_body.fetch("records").first.fetch("bindings").first
    expect(binding).to include("deployment_state" => "not_required", "verification_state" => "not_required",
                              "applied_source_revision" => "revision:1")
    expect(binding.fetch("binding_id")).to match(/\Adbb_[a-f0-9]{32}\z/)
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json", headers: headers
    expect(response).to have_http_status(:ok), response.body
    save_contract_response("record-show.json")
  end

  it "does not mutate the connection or create native records on rejected authentication, direction, lane or origin" do
    bad = [source(lane: "unapproved"), source(canonical_url: "https://unapproved.example/article/")]
    bad.each do |data|
      publish(data)
      expect(response).to have_http_status(:forbidden), response.body
    end
    publish(source, extra_headers: { "X-DiscussionBridge-Secret" => "not-the-secret" })
    expect(response).to have_http_status(:unauthorized), response.body
    expect(@connection.reload.last_seen_at).to be_nil
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "retains held source-author discovery so an operator can map and then publish" do
    @connection.update!(authorship_mode: "mapped", unmapped_author_policy: "hold")
    authored = source(source_authors: [{ source_author_id: "editor:41", source_author_name: "Source Editor",
                                        source_author_url: "https://publisher.example/authors/editor/" }],
                      primary_source_author_id: "editor:41")
    publish(authored)
    expect(response).to have_http_status(:forbidden), response.body
    observed = @connection.source_authors.find_by!(source_author_id: "editor:41")
    expect(observed.discourse_user_id).to be_nil
    expect(@connection.reload.last_seen_at).to be_nil
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    observed.update!(discourse_user: actor)
    publish(authored)
    expect(response).to have_http_status(:created), response.body
    expect(record.topic.first_post.cooked).to include("Source Editor")
  end

  it "rejects the removed mode, incomplete integrity and malformed excerpt structures" do
    cases = [source(presentation_mode: "fullInteractive"), source(source_content_sha256: "a" * 64)]
    excerpts = [
      '<p>This is an excerpt.</p><p><a href="https://publisher.example/articles/durable/">Read More</a><span>extra</span></p>',
      '<script>alert(1)</script><p>This is an excerpt.</p><p><a href="https://publisher.example/articles/durable/">Read More</a></p>',
      '<p class="notice">This is an excerpt.</p><p><a href="https://publisher.example/articles/durable/">Read More</a></p>',
    ]
    cases += excerpts.map do |html|
      source(content_html: html, content_disposition: "excerpt", read_more_url: source[:canonical_url], source_content_bytes: 1_000_000)
    end
    cases.each do |data|
      publish(data)
      expect(response).to have_http_status(:unprocessable_entity), response.body
    end
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(@connection.reload.last_seen_at).to be_nil
  end
end
