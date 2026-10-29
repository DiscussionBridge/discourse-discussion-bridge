# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsRecordsController do
  fab!(:admin)
  fab!(:author, :user)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.force_https = true
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_default_author_username = author.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    @connection, secret = DiscussionBridgeContentConnection.issue!(
      name: "Current To request fixture", platform: "ghost", author_user_id: author.id,
      allowed_origins: ["https://source.example"], allowed_directions: ["to_discourse"], allowed_lanes: %w[news other],
    )
    @connection.update!(cms_configuration: {
      "profile" => "ghost", "destination_origin" => "https://source.example", "publication_lane" => "news",
      "native_capabilities" => { "native_revision" => "native:fixture", "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic", "complete_content_supported" => true },
      "policy" => { "policy_revision" => SecureRandom.uuid, "enabled" => true, "selection" => "all_public",
        "category_ids" => [], "include_topic_ids" => [], "exclude_topic_ids" => [], "include_unlisted" => false,
        "publication_kind" => "dynamic", "presentation_mode" => "simple", "author_ids" => [], "taxonomy_ids" => [] },
    })
    @headers = { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => secret }
  end

  def source(revision: "native:r1", previous: nil, html: "<p>Owned current source body.</p>")
    {
      "direction" => "to_discourse", "external_id" => "article", "canonical_url" => "https://source.example/article/",
      "title" => "Current source discussion", "content_html" => html, "published" => true,
      "source_revision" => revision, "expected_source_revision" => previous,
      "source_created_at" => "2026-10-14T00:00:00.000Z", "source_updated_at" => nil,
      "representation" => { "kind" => "full" },
      "source_content_sha256" => Digest::SHA256.hexdigest(html.b), "source_content_bytes" => html.bytesize,
    }
  end

  def deliver(record, mutation_id: SecureRandom.uuid)
    post "/discussion-bridge/v4/bridge-records/resolve.json",
      params: { "mutation_id" => mutation_id, "bridge_record" => record }, headers: @headers, as: :json
  end

  def generated_source(article)
    complete = article + "<p>" + ('"' * 40_000) + "</p>"
    full = source(html: complete)
    measured = JSON.generate("mutation_id" => DiscussionBridge::CmsGeneratedExcerpt::MEASUREMENT_ID, "bridge_record" => full).bytesize
    full.merge("content_html" => article + DiscussionBridge::CmsGeneratedExcerpt.link(full.fetch("canonical_url")),
      "representation" => { "kind" => "generated_excerpt", "read_more_url" => full.fetch("canonical_url"),
        "article_content_bytes" => article.bytesize, "article_content_sha256" => Digest::SHA256.hexdigest(article.b),
        "selection_source_revision" => full.fetch("source_revision"), "selection_full_request_bytes" => measured })
  end

  def create_current(record = source, mutation_id: SecureRandom.uuid)
    deliver(record, mutation_id: mutation_id)
    expect(response).to have_http_status(:created)
    DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
  end

  def native_identity(record)
    post = record.topic.first_post
    [record.id, record.resource_id, record.topic_id, record.topic.url, post.id, post.user_id,
      record.active_binding("source").id, record.active_binding("source").external_id]
  end

  def expect_error(code)
    expect(response.status).to eq(DiscussionBridge::CmsProtocol::ERRORS.fetch(code).fetch("http"))
    expect(response.parsed_body.fetch("code")).to eq(code)
  end

  def expect_reconciliation(reason)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("outcome" => "reconciliation_required", "reason" => reason,
      "resource_id" => nil, "topic_id" => nil, "topic_url" => nil, "core_fallback" => false)
  end

  it "creates one typed current edition with native identities and the protected effective lane" do
    input = source
    record = create_current(input)
    expect(response.parsed_body.fetch("topic_id")).to eq(record.topic_id.to_s)
    expect(record.lane).to eq("news")
    expect(record.cms_source_publication.fetch("input")).to eq(input)
    expect(record.cms_source_publication.fetch("input")).not_to have_key("lane")
    expect(record.topic.first_post.user_id).to eq(author.id)
    expect(record.topic.visible).to eq(false)
    expect(DiscussionBridgeCmsToSourceRevision.where(bridge_record_id: record.id).pluck(:source_revision)).to eq(["native:r1"])
    expect(DiscussionBridgeCmsUrlReservation.find_by!(content_binding_id: record.active_binding("source").id).state).to eq("active")
  end

  it "returns typed invalid_field and rolls back a real native post-validation rejection" do
    native_creator = nil
    message = "Scoped native validation rejection fixture"
    handler = ->(post) { post.errors.add(:base, message) }
    # Exercise Core's real validation/error propagation, without choosing a
    # title rule or claiming this controlled rejection caused the WP failure.
    DiscourseEvent.on(:validate_post, &handler)
    allow_any_instance_of(::PostCreator).to receive(:create!).and_wrap_original do |original, *args|
      begin
        original.call(*args)
      rescue ActiveRecord::RecordNotSaved
        native_creator = original.receiver
        raise
      end
    end
    before = [Topic.count, Post.count, DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count,
      DiscussionBridgeCmsMutationReceipt.count, DiscussionBridgeCmsToSourceRevision.count, DiscussionBridgeCmsUrlReservation.count]

    deliver(source)

    expect(native_creator).to be_a(::PostCreator)
    expect(native_creator.errors.full_messages).to include(message)
    expect_error("invalid_field")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq("outcome" => "rejected", "code" => "invalid_field",
      "retryable" => false, "retry_after_seconds" => nil, "correlation_id" => nil, "core_fallback" => false)
    expect([Topic.count, Post.count, DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count,
      DiscussionBridgeCmsMutationReceipt.count, DiscussionBridgeCmsToSourceRevision.count, DiscussionBridgeCmsUrlReservation.count]).to eq(before)
  ensure
    DiscourseEvent.off(:validate_post, &handler) if handler
  end

  [ActiveRecord::RecordNotSaved, ArgumentError, ActiveRecord::RecordInvalid].each do |failure_class|
    it "does not reclassify after-commit #{failure_class} or discard its accepted receipt" do
      input = { "mutation_id" => SecureRandom.uuid, "bridge_record" => source }
      store = DiscussionBridge::CmsRecordStore.new(@connection)
      failure =
        if failure_class == ActiveRecord::RecordInvalid
          invalid_post = Post.new
          invalid_post.errors.add(:base, "after-commit fixture failure")
          ActiveRecord::RecordInvalid.new(invalid_post)
        else
          failure_class.new("after-commit fixture failure")
        end
      # Deliberately injected AFTER the real native creation/receipt transaction.
      # This is a boundary fixture, not a claim about the observed WP rejection.
      expect_any_instance_of(::PostCreator).to receive(:enqueue_jobs).once.and_raise(failure)

      expect { store.resolve(input) }.to raise_error { |error| expect(error).to equal(failure) }

      receipt = DiscussionBridgeCmsMutationReceipt.find_by!(content_connection_id: @connection.id,
        route: "record_resolve", mutation_id: input.fetch("mutation_id"))
      accepted = DiscussionBridge::CmsReceiptCipher.decrypt(receipt.response_body)
      record = DiscussionBridgeBridgeRecord.find_by!(resource_id: accepted.fetch("resource_id"))
      expect(receipt.response_status).to eq(201)
      expect(accepted).to include("outcome" => "created", "topic_id" => record.topic_id.to_s)
      expect(DiscussionBridge::CmsReceiptCipher.decrypt(receipt.request_tree)).to eq(input)
      expect(record.cms_source_publication.fetch("input")).to eq(input.fetch("bridge_record"))
      expect(record.topic.first_post.user_id).to eq(author.id)
      expect(record.active_binding("source").external_id).to eq("article")
      expect(DiscussionBridgeCmsToSourceRevision.where(bridge_record_id: record.id).pluck(:source_revision)).to eq(["native:r1"])

      retained = [record.attributes.deep_dup, record.topic.first_post.attributes.deep_dup,
        record.active_binding("source").attributes.deep_dup, receipt.attributes.deep_dup,
        DiscussionBridgeCmsToSourceRevision.where(bridge_record_id: record.id).map(&:attributes)]
      native_counts = [Topic.count, Post.count, DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count]
      expect_any_instance_of(::PostCreator).not_to receive(:create!)
      replay = store.resolve(input)
      expect(replay.status).to eq(201)
      expect(replay.body).to eq(accepted)
      expect([Topic.count, Post.count, DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count]).to eq(native_counts)
      expect([record.reload.attributes, record.topic.first_post.reload.attributes,
        record.active_binding("source").reload.attributes, receipt.reload.attributes,
        DiscussionBridgeCmsToSourceRevision.where(bridge_record_id: record.id).map(&:attributes)]).to eq(retained)
    end
  end

  it "uses captured source context for copied media while retaining accepted input evidence" do
    input = source(html: '<p><a href="../transcript#part">Transcript</a><img src="./image.png" alt="Diagram"></p>')
    original = input.deep_dup
    record = create_current(input)
    fragment = Nokogiri::HTML5.fragment(record.topic.first_post.raw)
    expect(fragment.at_css("a")["href"]).to eq("https://source.example/transcript#part")
    expect(fragment.at_css("img")["src"]).to eq("https://source.example/article/image.png")
    expect(record.cms_source_publication.fetch("input")).to eq(original)
    expect(record.cms_source_publication.fetch("input").fetch("source_content_sha256")).to eq(Digest::SHA256.hexdigest(original.fetch("content_html").b))
    expect(input).to eq(original)
    accepted_raw = record.topic.first_post.raw.dup
    allow(DiscussionBridge::PortableContent).to receive(:to_discourse_raw).and_call_original
    deliver(original.merge("expected_source_revision" => original.fetch("source_revision")))
    expect(DiscussionBridge::PortableContent).not_to have_received(:to_discourse_raw)
    expect(response).to have_http_status(:ok)
    expect(record.topic.first_post.reload.raw).to eq(accepted_raw)
    expect(record.reload.cms_source_publication.fetch("input")).to eq(original)
  end

  it "rolls back unsupported reference preparation without declaring source ineligible" do
    before = [DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count, Topic.count,
      DiscussionBridgeCmsMutationReceipt.count, DiscussionBridgeCmsToSourceRevision.count]
    deliver(source(html: '<p style="background:url(../background.png)">Valid source with unsupported copied CSS context</p>'))
    expect_error("content_preservation_unavailable")
    expect([DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count, Topic.count,
      DiscussionBridgeCmsMutationReceipt.count, DiscussionBridgeCmsToSourceRevision.count]).to eq(before)
  end

  it "validates whole input evidence before any native content conversion" do
    input = source(html: '<img src="./image.png" alt="Native source">')
    input["source_content_sha256"] = "0" * 64
    allow(DiscussionBridge::PortableContent).to receive(:to_discourse_raw).and_call_original
    deliver(input)
    expect(DiscussionBridge::PortableContent).not_to have_received(:to_discourse_raw)
    expect_error("content_hash_mismatch")
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeCmsToSourceRevision.count).to eq(0)
  end

  [
    '<script>PROGRAM_BODY_SENTINEL()</script>',
    '<script type="application/json">{"article_data":"INERT_DATA_SENTINEL"}</script>',
  ].each do |facility|
    it "rolls back actual native script/data loss and logs only scoped structural diagnostics for #{facility.include?('application/json') ? 'inert data' : 'script'}" do
      logs = []
      allow(Rails.logger).to receive(:warn) { |line| logs << line }
      input = source(html: "<p>Retained article paragraph.</p>#{facility}")
      input["correlation_id"] = SecureRandom.uuid
      mutation = SecureRandom.uuid
      before = [Topic.count, Post.count, DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count,
        DiscussionBridgeCmsMutationReceipt.count, DiscussionBridgeCmsToSourceRevision.count, DiscussionBridgeCmsUrlReservation.count]
      deliver(input, mutation_id: mutation)
      expect_error("content_preservation_unavailable")
      expect([Topic.count, Post.count, DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count,
        DiscussionBridgeCmsMutationReceipt.count, DiscussionBridgeCmsToSourceRevision.count, DiscussionBridgeCmsUrlReservation.count]).to eq(before)
      entry = logs.filter_map { |line| JSON.parse(line.to_s) rescue nil }
        .find { |row| row["event"] == "discussion_bridge_native_content_loss" }
      expect(entry).to include("connection_id" => @connection.public_id, "external_id" => input.fetch("external_id"),
        "source_revision" => input.fetch("source_revision"), "correlation_id" => input.fetch("correlation_id"), "mutation_id" => mutation)
      expect(entry.fetch("losses")).to include(hash_including("kind" => "script_nonempty_data_removed_or_changed"))
      expect(JSON.generate(entry)).not_to include("PROGRAM_BODY_SENTINEL", "INERT_DATA_SENTINEL", @headers.fetch("X-DiscussionBridge-Secret"), "content_html")
    end
  end

  it "rolls back an owned revision whose actual native cooking removed control or handler facilities" do
    record = create_current
    old_post = record.topic.first_post.attributes.deep_dup
    old_record = record.attributes.deep_dup
    old_binding = record.active_binding("source").attributes.deep_dup
    old_revisions = DiscussionBridgeCmsToSourceRevision.order(:id).map(&:attributes)
    old_receipts = DiscussionBridgeCmsMutationReceipt.order(:id).map(&:attributes)
    deliver(source(revision: "native:r2", previous: "native:r1", html: '<p>Changed article</p><form action="https://source.example/submit"><button onclick="HANDLER_SENTINEL()">Submit</button></form>'))
    expect_error("content_preservation_unavailable")
    expect(record.topic.first_post.reload.attributes).to eq(old_post)
    expect(record.reload.attributes).to eq(old_record)
    expect(record.active_binding("source").attributes).to eq(old_binding)
    expect(DiscussionBridgeCmsToSourceRevision.order(:id).map(&:attributes)).to eq(old_revisions)
    expect(DiscussionBridgeCmsMutationReceipt.order(:id).map(&:attributes)).to eq(old_receipts)
  end

  it "accepts escaped displayed code rather than declaring it executable source" do
    record = create_current(source(html: '<p>Displayed example</p><pre><code>&lt;script&gt;example()&lt;/script&gt;</code></pre>'))
    cooked = Nokogiri::HTML5.fragment(record.topic.first_post.cooked)
    expect(cooked.at_css("script")).to be_nil
    expect(cooked.at_css("code").text).to include("<script>example()</script>")
  end

  it "accepts actual retained native video/source player markup" do
    record = create_current(source(html: '<p>Source video</p><video controls><source src="https://source.example/video.mp4" type="video/mp4"></video>'))
    cooked = Nokogiri::HTML5.fragment(record.topic.first_post.cooked)
    expect(cooked.at_css("video[controls] source")["src"]).to eq("https://source.example/video.mp4")
  end

  it "does not re-cook or re-check an exact accepted current edition on replay" do
    input = source
    record = create_current(input)
    native = record.topic.first_post.attributes.deep_dup
    allow(DiscussionBridge::NativeContentPreservation).to receive(:verify!).and_call_original
    deliver(input.merge("expected_source_revision" => input.fetch("source_revision")))
    expect(DiscussionBridge::NativeContentPreservation).not_to have_received(:verify!)
    expect(response).to have_http_status(:ok)
    expect(record.topic.first_post.reload.attributes).to eq(native)
  end

  it "returns the permanent preservation error when required native article evidence is unavailable" do
    # Controlled unavailable RETURNED native evidence after real creation; this
    # is a receiver boundary fixture, not proof Core normally returns nil.
    allow_any_instance_of(PostCreator).to receive(:create!).and_wrap_original do |original, *args|
      original.call(*args).tap { |post| post.cooked = nil }
    end
    logs = []
    allow(Rails.logger).to receive(:warn) { |line| logs << line }
    deliver(source)
    expect_error("content_preservation_unavailable")
    expect(response.parsed_body).to eq("outcome" => "rejected", "code" => "content_preservation_unavailable",
      "retryable" => false, "retry_after_seconds" => nil, "correlation_id" => nil, "core_fallback" => false)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeCmsMutationReceipt.count).to eq(0)
    event = logs.filter_map { |line| JSON.parse(line.to_s) rescue nil }.find { |row| row["event"] == "discussion_bridge_native_content_loss" }
    expect(event.fetch("diagnostic_kind")).to eq("article_unavailable")
  end

  it "rolls back generated-link move cooking loss before reservations, history or receipt commit" do
    input = generated_source('<p>Article video</p><video controls><source src="https://source.example/video.mp4" type="video/mp4"></video>')
    input["correlation_id"] = SecureRandom.uuid
    record = create_current(input)
    native = record.topic.first_post
    time = Time.at((Time.current.to_r * 1000).floor / 1000r).utc
    store = DiscussionBridge::CmsSourceMoveStore.new(@connection, clock: -> { time })
    prepared = store.prepare(record.resource_id, { "mutation_id" => SecureRandom.uuid, "expected_source_revision" => "native:r1",
      "old_url" => input.fetch("canonical_url"), "new_url" => "https://source.example/moved/", "external_id" => input.fetch("external_id") })
    move = DiscussionBridgeCmsUrlMove.find_by!(move_id: prepared.body.fetch("move_id"))
    before = { native: native.attributes.deep_dup, record: record.reload.attributes.deep_dup,
      binding: record.active_binding("source").attributes.deep_dup, move: move.attributes.deep_dup,
      reservations: DiscussionBridgeCmsUrlReservation.order(:id).map(&:attributes),
      revisions: DiscussionBridgeCmsToSourceRevision.order(:id).map(&:attributes),
      receipts: DiscussionBridgeCmsMutationReceipt.order(:id).map(&:attributes) }
    allow_any_instance_of(Post).to receive(:cook).and_wrap_original do |original, *args|
      cooked = original.call(*args)
      if original.receiver.id == native.id
        # Simulated native AFTER-cooking filter removes a formerly supported
        # player. We compare the actual resulting cooked value, not Core defaults.
        fragment = Nokogiri::HTML5.fragment(cooked)
        fragment.css("video").remove
        fragment.to_html
      else
        cooked
      end
    end
    logs = []
    allow(Rails.logger).to receive(:warn) { |line| logs << line }
    # Synthetic report fields exercise ONLY this negative local transaction.
    # No source-native/public verifier/profile or successful proof is asserted.
    attempt = { "mutation_id" => SecureRandom.uuid, "move_id" => move.move_id, "proof_nonce" => move.proof_nonce,
      "expected_source_revision" => "native:r1", "new_source_revision" => "native:r2", "source_updated_at" => nil,
      "verification" => { "url" => move.new_url, "external_id" => input.fetch("external_id"), "source_revision" => "native:r2",
        "source_content_sha256" => input.fetch("source_content_sha256"), "native_ownership_receipt_sha256" => "1" * 64,
        "native_publication_sha256" => "2" * 64, "verification_profile" => "local-negative-fixture", "checked_at" => DiscussionBridge::CmsProtocol.instant(time) } }
    allow(DiscussionBridge::CmsMoveReservation).to receive(:commit!).and_call_original
    expect { store.finalize(record.resource_id, move.move_id, attempt) }.to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq("content_preservation_unavailable")
    }
    expect(DiscussionBridge::CmsMoveReservation).not_to have_received(:commit!)
    expect(native.reload.attributes).to eq(before.fetch(:native))
    expect(record.reload.attributes).to eq(before.fetch(:record))
    expect(record.active_binding("source").attributes).to eq(before.fetch(:binding))
    expect(move.reload.attributes).to eq(before.fetch(:move))
    expect(DiscussionBridgeCmsUrlReservation.order(:id).map(&:attributes)).to eq(before.fetch(:reservations))
    expect(DiscussionBridgeCmsToSourceRevision.order(:id).map(&:attributes)).to eq(before.fetch(:revisions))
    expect(DiscussionBridgeCmsMutationReceipt.order(:id).map(&:attributes)).to eq(before.fetch(:receipts))
    event = logs.filter_map { |line| JSON.parse(line.to_s) rescue nil }.find { |row| row["event"] == "discussion_bridge_native_content_loss" }
    expect(event).to include("resource_id" => record.resource_id, "external_id" => input.fetch("external_id"),
      "source_revision" => "native:r2", "mutation_id" => attempt.fetch("mutation_id"), "correlation_id" => nil,
      "diagnostic_kind" => "observed_content_loss")
  end

  it "preserves supported native output during the owned generated edit without asserting public proof" do
    input = generated_source('<p>Article video</p><video controls><source src="https://source.example/video.mp4" type="video/mp4"></video>')
    record = create_current(input)
    native = record.topic.first_post
    original = native.attributes.deep_dup
    receipt = record.cms_source_publication.deep_dup
    projected = DiscussionBridge::CmsGeneratedExcerpt.project_move(input, "https://source.example/moved/", "native:r2", nil)
    raw = DiscussionBridge::CmsGeneratedExcerpt.replace_native(receipt.fetch("generated_native_segment"), native.raw, projected.fetch("canonical_url"))
    store = DiscussionBridge::CmsSourceMoveStore.new(@connection)
    DiscussionBridgeBridgeRecord.transaction do
      store.send(:edit_generated_native!, record, native, raw, source_input: projected, source_article_url: input.fetch("canonical_url"))
      expect(native.raw).to eq(raw)
      expect(Nokogiri::HTML5.fragment(native.cooked).at_css("video[controls] source")["src"]).to eq("https://source.example/video.mp4")
      expect(native.raw).to include("Originally published at [#{input.fetch('canonical_url')}]")
      # This fixture validates the actual native edit/check only. Deliberately
      # roll it back; no finalize/public proof or accepted move is fabricated.
      raise ActiveRecord::Rollback
    end
    expect(native.reload.attributes).to eq(original)
    expect(record.reload.cms_source_publication).to eq(receipt)
  end

  it "replays the exact original mutation without rewriting native data or accepted receipts" do
    input = source
    id = SecureRandom.uuid
    record = create_current(input, mutation_id: id)
    original_response = response.parsed_body.deep_dup
    original_native = record.topic.first_post.attributes.deep_dup
    original_receipt = DiscussionBridgeCmsMutationReceipt.find_by!(mutation_id: id).attributes.deep_dup
    deliver(input, mutation_id: id)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to eq(original_response)
    expect(record.topic.first_post.reload.attributes).to eq(original_native)
    expect(DiscussionBridgeCmsMutationReceipt.find_by!(mutation_id: id).attributes).to eq(original_receipt)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
    expect(DiscussionBridgeCmsToSourceRevision.count).to eq(1)
  end

  it "rejects a changed tree under an accepted mutation ID" do
    id = SecureRandom.uuid
    record = create_current(source, mutation_id: id)
    raw = record.topic.first_post.raw
    deliver(source(html: "<p>Different caller tree.</p>"), mutation_id: id)
    expect_error("mutation_conflict")
    expect(record.topic.first_post.reload.raw).to eq(raw)
  end

  it "resolves an exact same edition with current predecessor and no native rewrite" do
    record = create_current
    before = record.topic.first_post.attributes.deep_dup
    deliver(source(previous: "native:r1"))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("outcome")).to eq("resolved")
    expect(record.topic.first_post.reload.attributes).to eq(before)
    expect(DiscussionBridgeCmsToSourceRevision.count).to eq(1)
  end

  it "rejects changed content with the same accepted source revision" do
    record = create_current
    before = record.topic.first_post.raw
    deliver(source(previous: "native:r1", html: "<p>Changed same-edition bytes.</p>"))
    expect_error("revision_conflict")
    expect(record.topic.first_post.reload.raw).to eq(before)
    expect(DiscussionBridgeCmsToSourceRevision.count).to eq(1)
  end

  it "applies an ordinary owned source edit to the same wiki post and discussion" do
    record = create_current
    first_post = record.topic.first_post
    admin.guardian.ensure_can_wiki!(first_post)
    expect(first_post.revise(admin, wiki: true)).to eq(true)
    expect(first_post.reload.wiki).to eq(true)
    identity = native_identity(record)
    reply = Fabricate(:post, topic: record.topic, post_number: 2, user: admin)
    deliver(source(revision: "native:r2", previous: "native:r1", html: "<p>Updated authoritative source body.</p>"))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("outcome")).to eq("updated")
    expect(native_identity(record.reload)).to eq(identity)
    expect(record.topic.first_post.reload.wiki).to eq(true)
    expect(record.topic.first_post.raw).to include("Updated authoritative source body.")
    expect(reply.reload.topic_id).to eq(record.topic_id)
    expect(DiscussionBridgeCmsToSourceRevision.where(bridge_record_id: record.id).order(:id).pluck(:source_revision)).to eq(%w[native:r1 native:r2])
  end

  it "protects an independent human wiki-body edit from new and same-edition source writes" do
    record = create_current
    first_post = record.topic.first_post
    admin.guardian.ensure_can_wiki!(first_post)
    expect(first_post.revise(admin, wiki: true)).to eq(true)
    expect(first_post.reload.wiki).to eq(true)
    expect(first_post.revise(admin, raw: "A retained human wiki-body correction.")).to eq(true)
    local = first_post.reload.attributes.deep_dup
    [source(revision: "native:r2", previous: "native:r1"), source(previous: "native:r1")].each do |input|
      deliver(input)
      expect_reconciliation("native_ownership_conflict")
      expect(first_post.reload.attributes).to eq(local)
    end
    expect(DiscussionBridgeCmsToSourceRevision.count).to eq(1)
  end

  it "does not silently move a bound lane when an omitted-lane configuration changes" do
    record = create_current
    configuration = @connection.cms_configuration.deep_dup
    configuration["publication_lane"] = "other"
    @connection.update!(cms_configuration: configuration)
    deliver(source(previous: "native:r1"))
    expect_reconciliation("identity_conflict")
    expect(record.reload.lane).to eq("news")
  end

  it "refuses an unexpected predecessor without changing the current native edition" do
    record = create_current
    raw = record.topic.first_post.raw
    deliver(source(revision: "native:r2", previous: "unknown:edition"))
    expect_error("revision_conflict")
    expect(record.topic.first_post.reload.raw).to eq(raw)
    expect(record.reload.cms_source_publication.fetch("revision")).to eq("native:r1")
  end

  it "reports unavailable owned native content without implying failed Core embed association" do
    record = create_current
    raw = record.topic.first_post.raw
    record.topic.update!(deleted_at: Time.current)
    deliver(source(previous: "native:r1"))
    expect_reconciliation("native_ownership_conflict")
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
    expect(record.topic.first_post.reload.raw).to eq(raw)
    expect(DiscussionBridgeCmsToSourceRevision.count).to eq(1)
  end

  it "withdraws only delivery while retaining topic, discussion, identity and immutable history" do
    record = create_current
    identity = native_identity(record)
    before = record.cms_source_publication.deep_dup
    raw = record.topic.first_post.raw
    post "/discussion-bridge/v4/bridge-records/#{record.resource_id}/withdraw.json",
      params: { mutation_id: SecureRandom.uuid, expected_source_revision: "native:r1", reason: "policy_excluded" },
      headers: @headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("state" => "withdrawn", "source_revision" => "native:r1", "mapping_id" => nil)
    expect(native_identity(record.reload)).to eq(identity)
    expect(record.topic.first_post.reload.raw).to eq(raw)
    expect(record.topic.deleted_at).to be_nil
    expect(record.cms_source_publication.except("state", "withdrawal_reason", "withdrawn_at")).to eq(before.except("state"))
    expect(DiscussionBridgeCmsToSourceRevision.count).to eq(1)
    deliver(source(revision: "native:r2", previous: "native:r1"))
    expect_reconciliation("native_ownership_conflict")
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
    expect(record.topic.first_post.reload.raw).to eq(raw)
    get "/discussion-bridge/v4/bridge-records/#{record.resource_id}.json", headers: @headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("state")).to eq("withdrawn")
  end

  it "captures the owned native generated segment for a truthful envelope-only excerpt" do
    complete = "<p>" + ('"' * 40_000) + "</p>"
    full = source(html: complete)
    measured = JSON.generate("mutation_id" => DiscussionBridge::CmsGeneratedExcerpt::MEASUREMENT_ID, "bridge_record" => full).bytesize
    expect(complete.bytesize).to be <= 49_152
    expect(measured).to be > 65_536
    article = "<p>A truthful article excerpt.</p>"
    input = full.merge("content_html" => article + DiscussionBridge::CmsGeneratedExcerpt.link(full.fetch("canonical_url")),
      "representation" => { "kind" => "generated_excerpt", "read_more_url" => full.fetch("canonical_url"),
        "article_content_bytes" => article.bytesize, "article_content_sha256" => Digest::SHA256.hexdigest(article.b),
        "selection_source_revision" => "native:r1", "selection_full_request_bytes" => measured })
    record = create_current(input)
    expect(record.cms_source_publication.fetch("content_sha256")).to eq(Digest::SHA256.hexdigest(complete.b))
    expect(record.cms_source_publication.fetch("content_bytes")).to eq(complete.bytesize)
    expect(record.cms_source_publication.fetch("excerpted")).to eq(true)
    expect(record.cms_source_publication.fetch("generated_native_segment")).to eq(
      DiscussionBridge::CmsGeneratedExcerpt.capture_native(input, record.topic.first_post.raw),
    )
  end
end
