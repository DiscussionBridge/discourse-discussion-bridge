# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge automatic native source revision capture" do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Automatic sources", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
  end

  def publication(connection: @connection, topic: nil, first_post: nil)
    topic ||= Fabricate(:topic, user: admin, category: category)
    first_post ||= Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "The original complete source article.")
    sign_in(admin)
    post "/discussion-bridge/v1/publisher/topics/#{topic.id}/publish.json", params: { publication: {
      content_connection_id: connection.id, external_id: "article:#{topic.id}",
      canonical_url: "https://native.example/articles/#{topic.id}/", presentation_mode: "interactive",
    } }, as: :json
    expect([200, 201]).to include(response.status), response.body
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    sign_out
    [topic, first_post, record, record.active_binding("presentation")]
  end

  def run(binding)
    Jobs::DiscussionBridgeCaptureSourceRevisions.new.execute(topic_id: binding.bridge_record.topic_id, cut: binding.id, position: 0)
  end

  def revision_read(topic, revision, name)
    get "/discussion-bridge/v1/source-topics/#{topic.id}.json", params: { source_revision: revision }, headers: auth_headers
    expect(response).to have_http_status(:ok), response.body
    receipt(name)
    response.parsed_body
  end

  def auth_headers
    { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "automatic-source-test", "HTTPS" => "on" }
  end

  def receipt(name)
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    File.binwrite(File.join(directory, name), response.body) if directory
  end

  it "captures a real first-post edit through the native event and worker without changing publication identity or source history" do
    topic, first_post, record, binding = publication
    identity = record.attributes.slice("id", "resource_id", "topic_id", "state")
    binding_before = binding.attributes
    original = record.native_source_revisions.sole.attributes
    expect_enqueued_with(job: :discussion_bridge_capture_source_revisions, args: { topic_id: topic.id, cut: binding.id, position: 0 }) do
      PostRevisor.new(first_post).revise!(admin, { raw: "A changed source body with **rich content**." }, force_new_version: true)
    end
    source = first_post.reload.attributes
    native_history = PostRevision.where(post_id: first_post.id).pluck(:id)
    run(binding)
    expect(record.reload.source_revision_sequence).to eq(2)
    expect(record.attributes.slice(*identity.keys)).to eq(identity)
    expect(binding.reload.attributes).to eq(binding_before)
    expect(first_post.reload.attributes).to eq(source)
    expect(PostRevision.where(post_id: first_post.id).pluck(:id)).to eq(native_history)
    expect(record.native_source_revisions.order(:sequence).first.attributes).to eq(original)
    value = revision_read(topic, record.source_revision, "automatic-source-detail.json")
    expect(value.fetch("source_updated_at")).to eq(first_post.updated_at.utc.iso8601(6))
    expect(value.fetch("source_created_at")).to eq(first_post.created_at.utc.iso8601(6))
    expect(value.fetch("content_transport").fetch("content_html")).to eq(first_post.cooked)
    expect(value.fetch("source_revision_sequence")).to eq(2)
  end

  it "captures wiki edits and reversions with new sequences and unchanged native identity" do
    topic, first_post, record, binding = publication
    original_raw = first_post.raw
    PostRevisor.new(first_post).revise!(admin, { wiki: true }, force_new_version: true)
    run(binding)
    expect(record.reload.source_revision_sequence).to eq(2)
    expect(record.native_source_revisions.order(:sequence).last.metadata.fetch("wiki")).to eq(true)
    PostRevisor.new(first_post.reload).revise!(admin, { raw: "An edited collaborative wiki." }, force_new_version: true)
    run(binding)
    expect(record.reload.source_revision_sequence).to eq(3)
    PostRevisor.new(first_post.reload).revise!(admin, { raw: original_raw }, force_new_version: true)
    run(binding)
    expect(record.reload.source_revision_sequence).to eq(4)
    expect(record.native_source_revisions.order(:sequence).last.content_html).to eq(first_post.reload.cooked)
    expect(record.topic_id).to eq(topic.id)
    expect(record.native_source_revisions.pluck(:revision).uniq.length).to eq(4)
  end

  it "captures native first-post title and taxonomy edits rather than inventing a separate timestamp" do
    topic, first_post, record, binding = publication
    SiteSetting.tagging_enabled = true
    tag = Fabricate(:tag, name: "native-source")
    PostRevisor.new(first_post).revise!(admin, { title: "A native source title change", tags: [tag.name] }, force_new_version: true)
    run(binding)
    capture = record.reload.native_source_revisions.order(:sequence).last
    expect(capture.metadata.fetch("title")).to eq(topic.reload.title)
    expect(capture.metadata.fetch("tag_ids")).to eq([tag.id])
    expect(capture.metadata.fetch("tags").sole.fetch("source_tag_name")).to eq(tag.name)
    expect(record.source_updated_at_raw).to eq(first_post.reload.updated_at.utc.iso8601(6))
  end

  it "makes duplicate and delayed callbacks idempotent while retaining the latest actual source state" do
    _topic, first_post, record, binding = publication
    PostRevisor.new(first_post).revise!(admin, { raw: "Intermediate native edit." }, force_new_version: true)
    PostRevisor.new(first_post.reload).revise!(admin, { raw: "Latest native edit." }, force_new_version: true)
    run(binding)
    retained = record.reload.native_source_revisions.order(:sequence).last.attributes
    observed = DiscussionBridgeSourceInventoryEntry.order(:id).last.attributes
    2.times { run(binding) }
    expect(record.native_source_revisions.count).to eq(2)
    expect(record.native_source_revisions.order(:sequence).last.attributes).to eq(retained)
    expect(retained.fetch("content_html")).to eq(first_post.reload.cooked)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(2)
    expect(DiscussionBridgeSourceInventoryEntry.order(:id).last.attributes).to eq(observed)
  end

  it "does not create publications for unmapped topics, replies or To-Discourse records" do
    topic = Fabricate(:topic, user: admin, category: category)
    first_post = Fabricate(:post, topic: topic, user: admin, post_number: 1)
    expect_not_enqueued_with(job: :discussion_bridge_capture_source_revisions) do
      PostRevisor.new(first_post).revise!(admin, { raw: "An unmapped source edit." }, force_new_version: true)
    end
    topic, _first_post, record, binding = publication
    reply = Fabricate(:post, topic: topic, user: admin, post_number: 2)
    expect_not_enqueued_with(job: :discussion_bridge_capture_source_revisions) do
      PostRevisor.new(reply).revise!(admin, { raw: "A reply edit is not the source article." }, force_new_version: true)
    end
    record.update!(direction: "to_discourse")
    expect_not_enqueued_with(job: :discussion_bridge_capture_source_revisions) do
      DiscussionBridge::SourceRevisionProducer.enqueue("topic_id" => topic.id)
    end
    run(binding)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
    expect(record.native_source_revisions.count).to eq(1)
  end

  it "rechecks each publisher setting and disabled connection before changing retained context" do
    _topic, first_post, record, binding = publication
    PostRevisor.new(first_post).revise!(admin, { raw: "A legitimate edit while disabled." }, force_new_version: true)
    %i[discussion_bridge_enabled discussion_bridge_endpoint_enabled discussion_bridge_publisher_enabled].each do |setting|
      SiteSetting.public_send("#{setting}=", false)
      run(binding)
      expect(record.native_source_revisions.count).to eq(1)
      SiteSetting.public_send("#{setting}=", true)
    end
    @connection.update!(enabled: false)
    run(binding)
    expect(record.native_source_revisions.count).to eq(1)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(1)
  end

  it "leaves deleted or private source revisions untouched until current eligibility returns" do
    _topic, first_post, record, binding = publication
    PostRevisor.new(first_post).revise!(admin, { raw: "Edited before becoming private." }, force_new_version: true)
    first_post.update_columns(deleted_at: Time.now.utc)
    run(binding)
    expect(record.native_source_revisions.count).to eq(1)
    first_post.update_columns(deleted_at: nil)
    category.update!(permissions: { "staff" => 1 })
    run(binding)
    expect(record.native_source_revisions.count).to eq(1)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(1)
  end

  it "does not use a delayed update job to bypass origin, lane or direction scope" do
    _topic, first_post, record, binding = publication
    PostRevisor.new(first_post).revise!(admin, { raw: "Updated authorized native text." }, force_new_version: true)
    original = @connection.attributes.slice("allowed_origins", "allowed_lanes", "allowed_directions")
    [ { allowed_origins: ["https://other.example"] }, { allowed_lanes: ["articles"] },
      { allowed_directions: ["to_discourse"] } ].each do |scope|
      @connection.update!(scope)
      run(binding)
      expect(record.native_source_revisions.count).to eq(1)
      @connection.update!(original)
    end
  end

  it "restores a natively deleted first post using one higher revision even when native content and clocks are unchanged" do
    topic, first_post, record, binding = publication
    identity = [record.resource_id, record.topic_id, binding.public_id, binding.canonical_url]
    PostDestroyer.new(admin, first_post).destroy
    notice = DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
    notice_before = notice.attributes
    expect_enqueued_with(job: :discussion_bridge_capture_source_revisions, args: { topic_id: topic.id, cut: binding.id, position: 0 }) do
      PostDestroyer.new(admin, first_post.reload).recover
    end
    # Native recovery may change metadata, but unchanged eligible bytes/clocks
    # must also advance: retain the previous capture's native metadata exactly.
    original = record.native_source_revisions.sole
    first_post.update_columns(updated_at: Time.iso8601(original.metadata.fetch("source_updated_at")))
    source = first_post.reload.attributes
    run(binding)
    expect(record.reload.source_revision_sequence).to eq(notice.source_revision_sequence + 1)
    expect([record.resource_id, record.topic_id, binding.reload.public_id, binding.canonical_url]).to eq(identity)
    expect(first_post.reload.attributes).to eq(source)
    expect(notice.reload.attributes).to eq(notice_before)
    expect(record.source_updated_at_raw).to eq(original.metadata.fetch("source_updated_at"))
    restored = record.native_source_revisions.order(:sequence).last.attributes
    2.times { run(binding) }
    expect(record.native_source_revisions.count).to eq(2)
    expect(record.native_source_revisions.order(:sequence).last.attributes).to eq(restored)
    value = revision_read(topic, record.source_revision, "restored-source-detail.json")
    expect(value.fetch("source_revision_sequence")).to eq(2)
    expect(value.fetch("content_transport").fetch("content_html")).to eq(first_post.cooked)
  end

  it "captures a higher revision when category privacy returns to public" do
    topic, _first_post, record, binding = publication
    category.update!(permissions: { "staff" => 1 })
    notice = DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
    expect(notice.reason).to eq("source_unpublished")
    expect_enqueued_with(job: :discussion_bridge_capture_source_revisions, args: { category_id: category.id, cut: binding.id, position: 0 }) do
      category.update!(permissions: { "everyone" => 1 })
    end
    run(binding)
    expect(record.reload.source_revision_sequence).to eq(2)
    expect(Guardian.new.can_see?(topic.reload)).to eq(true)
  end

  it "restores scope without reusing the withdrawn sequence, including repeated cycles" do
    _topic, _first_post, record, binding = publication
    2.times do |index|
      @connection.update!(allowed_origins: ["https://other.example"])
      notice = DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
      expect(notice.source_revision_sequence).to eq(index + 1)
      expect_enqueued_with(job: :discussion_bridge_capture_source_revisions,
        args: { content_connection_id: @connection.id, cut: binding.id, position: 0 }) do
        @connection.update!(allowed_origins: ["https://native.example"])
      end
      run(binding)
      run(binding)
      expect(record.reload.source_revision_sequence).to eq(index + 2)
    end
    expect(DiscussionBridgeSourceRevocation.count).to eq(2)
    expect(record.native_source_revisions.count).to eq(3)
  end

  it "makes explicit re-publication after withdrawal use the same restoration rule" do
    topic, first_post, record, binding = publication
    first_post.update_columns(deleted_at: Time.now.utc)
    DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
    first_post.update_columns(deleted_at: nil)
    publication(topic: topic, first_post: first_post)
    expect(record.reload.source_revision_sequence).to eq(2)
    run(binding)
    expect(record.native_source_revisions.count).to eq(2)
  end

  it "isolates independent connections publishing the same source topic" do
    topic, first_post, record, binding = publication
    other, = DiscussionBridgeContentConnection.issue!(name: "Other source destination", platform: "astro",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
    _topic, _first_post, other_record, other_binding = publication(connection: other, topic: topic, first_post: first_post)
    expect(other_record.resource_id).not_to eq(record.resource_id)
    expect(other_binding.public_id).not_to eq(binding.public_id)
    PostRevisor.new(first_post).revise!(admin, { raw: "One source, independent destinations." }, force_new_version: true)
    @connection.update!(enabled: false)
    Jobs::DiscussionBridgeCaptureSourceRevisions.new.execute(topic_id: topic.id, cut: other_binding.id, position: 0)
    expect(record.reload.source_revision_sequence).to eq(1)
    expect(other_record.reload.source_revision_sequence).to eq(2)
  end

  it "keeps the original inventory cut and retained detail through an automatic revision" do
    topic, first_post, record, binding = publication
    old_revision = record.source_revision
    old_body = first_post.cooked
    get "/discussion-bridge/v1/source-topics.json", headers: auth_headers
    expect(response).to have_http_status(:ok), response.body
    receipt("automatic-before-inventory.json")
    cut = response.parsed_body
    PostRevisor.new(first_post).revise!(admin, { raw: "New body after the fixed inventory cut." }, force_new_version: true)
    run(binding)
    get "/discussion-bridge/v1/source-topics.json", params: { snapshot: cut.fetch("snapshot") }, headers: auth_headers
    expect(response).to have_http_status(:ok), response.body
    receipt("automatic-pinned-inventory.json")
    expect(response.parsed_body.fetch("items").sole.fetch("source_revision")).to eq(old_revision)
    get "/discussion-bridge/v1/source-topics.json", headers: auth_headers
    expect(response).to have_http_status(:ok), response.body
    receipt("automatic-after-inventory.json")
    expect(response.parsed_body.fetch("items").sole.fetch("source_revision")).to eq(record.reload.source_revision)
    expect(revision_read(topic, old_revision, "automatic-old-source-detail.json").fetch("content_transport").fetch("content_html")).to eq(old_body)
  end

  it "rolls back a new capture when observation fails and retries without partial state" do
    _topic, first_post, record, binding = publication
    before = record.reload.attributes
    PostRevisor.new(first_post).revise!(admin, { raw: "New source awaiting a successful observation." }, force_new_version: true)
    DiscussionBridgeSourceInventoryEntry.stubs(:create!).raises(ArgumentError, "Synthetic observation failure")
    expect { run(binding) }.to raise_error(ArgumentError, "Synthetic observation failure")
    expect(record.reload.attributes).to eq(before)
    expect(record.native_source_revisions.count).to eq(1)
    DiscussionBridgeSourceInventoryEntry.unstub(:create!)
    run(binding)
    expect(record.reload.source_revision_sequence).to eq(2)
    expect(DiscussionBridgeSourceInventoryEntry.count).to eq(2)
  end

  it "fails closed on unknown, tampered or substituted native identity without editing sources" do
    _topic, first_post, record, binding = publication
    original = record.attributes
    record.update_columns(source_revision: nil)
    expect { run(binding) }.to raise_error(ArgumentError, "source revision context requires reconciliation")
    record.update_columns(source_revision: original.fetch("source_revision"))
    entry = DiscussionBridgeSourceInventoryEntry.sole
    DiscussionBridgeSourceInventoryEntry.where(id: entry.id).update_all(context_digest: "0" * 64)
    expect { run(binding) }.to raise_error(ArgumentError, "source update context requires reconciliation")
    DiscussionBridgeSourceInventoryEntry.where(id: entry.id).update_all(context_digest: entry.context_digest)
    first_post.update_columns(created_at: first_post.created_at - 1.second)
    expect { run(binding) }.to raise_error(ArgumentError, "native source identity requires reconciliation")
    expect(record.native_source_revisions.count).to eq(1)
  end

  it "rejects a tampered withdrawal instead of treating current public visibility as clearance" do
    _topic, first_post, record, binding = publication
    first_post.update_columns(deleted_at: Time.now.utc)
    notice = DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
    first_post.update_columns(deleted_at: nil)
    DiscussionBridgeSourceRevocation.where(id: notice.id).update_all(restorable: false)
    expect { run(binding) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error)
    expect(record.native_source_revisions.count).to eq(1)
  end

  it "does not clear valid operator or policy holds merely because the native source is public" do
    _topic, first_post, record, binding = publication
    first_post.update_columns(deleted_at: Time.now.utc)
    notice = DiscussionBridge::SourceRevocationProducer.call(binding_id: binding.id)
    first_post.update_columns(deleted_at: nil)
    %w[operator_hold policy_removed].each do |reason|
      attributes = notice.attributes.merge("reason" => reason)
      attributes["identity_digest"] = DiscussionBridge::NativeSourceRevisionCapture.fingerprint(attributes.slice(*DiscussionBridge::SourceRevocationProducer::FIELDS))
      attributes["context_digest"] = DiscussionBridge::SourceRevocationProducer.context_digest(attributes)
      DiscussionBridgeSourceRevocation.where(id: notice.id).update_all(attributes.slice("reason", "identity_digest", "context_digest"))
      expect(DiscussionBridge::SourceRevocationProducer.verify!(notice.reload)).to eq(notice)
      run(binding)
      expect(record.native_source_revisions.count).to eq(1)
      expect(DiscussionBridgeSourceInventoryEntry.count).to eq(1)
    end
  end

  it "refreshes previously observed content when a disabled connection is enabled again" do
    topic, first_post, record, binding = publication
    @connection.update!(enabled: false)
    PostRevisor.new(first_post).revise!(admin, { raw: "A source edit while this connection was disabled." }, force_new_version: true)
    expect_enqueued_with(job: :discussion_bridge_capture_source_revisions,
      args: { content_connection_id: @connection.id, cut: binding.id, position: 0 }) do
      @connection.update!(enabled: true)
    end
    run(binding)
    expect(record.reload.source_revision_sequence).to eq(2)
    expect(record.topic_id).to eq(topic.id)
  end

  it "bounds worker batches, excludes later bindings from the cut and rejects invalid continuations" do
    _first_topic, first_post, first_record, first_binding = publication
    _last_topic, last_post, last_record, last_binding = publication
    _later_topic, later_post, later_record, = publication
    [first_post, last_post, later_post].each { |native_post| PostRevisor.new(native_post).revise!(admin, { raw: "A changed finite-cut source." }, force_new_version: true) }
    stub_const(DiscussionBridge::SourceRevisionProducer, :BATCH_SIZE, 1) do
      expect_enqueued_with(job: :discussion_bridge_capture_source_revisions,
        args: { content_connection_id: @connection.id, cut: last_binding.id, position: first_binding.id }) do
        Jobs::DiscussionBridgeCaptureSourceRevisions.new.execute(content_connection_id: @connection.id, cut: last_binding.id, position: 0)
      end
      Jobs::DiscussionBridgeCaptureSourceRevisions.new.execute(content_connection_id: @connection.id, cut: last_binding.id, position: first_binding.id)
    end
    expect(first_record.reload.source_revision_sequence).to eq(2)
    expect(last_record.reload.source_revision_sequence).to eq(2)
    expect(later_record.reload.source_revision_sequence).to eq(1)
    expect { Jobs::DiscussionBridgeCaptureSourceRevisions.new.execute(content_connection_id: @connection.id, cut: last_binding.id, position: -1) }
      .to raise_error(ArgumentError, "invalid source update continuation")
  end
end
