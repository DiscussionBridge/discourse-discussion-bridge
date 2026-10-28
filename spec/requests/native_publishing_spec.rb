# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::PublisherController do
  fab!(:admin)
  fab!(:moderator)
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    # Isolate asynchronous scheduling only. Native request refresh, mapping
    # preparation, current-source checks and database transactions remain real.
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    # Core authentication cookies are secure under force_https. Exercise the
    # real native session over HTTPS rather than silently dropping that cookie.
    https!
    @connection, @secret = issue_connection("Native publisher fixture")
    @xhr_headers = { "X-Requested-With" => "XMLHttpRequest" }
  end

  def issue_connection(name)
    connection, secret = DiscussionBridgeContentConnection.issue!(
      name: name,
      platform: "ghost",
      allowed_origins: ["https://site.example", "https://other.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: %w[news other],
    )
    connection.update!(
      cms_configuration: {
        "profile" => "ghost",
        "destination_origin" => "https://site.example",
        "publication_lane" => "news",
        "native_capabilities" => {
          "native_revision" => "ghost:native-request-fixture",
          "supported_presentations" => %w[simple full],
          "publication_kind" => "dynamic",
          "complete_content_supported" => true,
        },
        "policy" => {
          "policy_revision" => SecureRandom.uuid,
          "enabled" => true,
          "selection" => "all_public",
          "category_ids" => [],
          "include_topic_ids" => [],
          "exclude_topic_ids" => [],
          "include_unlisted" => false,
          "publication_kind" => "dynamic",
          "presentation_mode" => "simple",
          "author_ids" => [],
          "taxonomy_ids" => [],
        },
      },
    )
    [connection, secret]
  end

  def publish(input = {}, native_topic: topic, connection: @connection, headers: @xhr_headers)
    post "/admin/publishing/topics/#{native_topic.id}/publish.json",
         params: {
           publication: {
             content_connection_id: connection.id,
             external_id: "article",
             canonical_url: "https://site.example/article/",
           }.merge(input),
         },
         headers: headers,
         as: :json
  end

  def correct(mapping, url)
    put "/admin/publishing/publications/#{mapping.content_binding.bridge_record.resource_id}/presentation.json",
        params: { publication: { canonical_url: url } },
        headers: @xhr_headers,
        as: :json
  end

  def create_publication
    sign_in(admin)
    publish
    expect(response).to have_http_status(:created)
    record = DiscussionBridgeBridgeRecord.find_by!(resource_id: response.parsed_body.fetch("resource_id"))
    DiscussionBridgeCmsMapping.find_by!(content_binding_id: record.active_binding("presentation").id)
  end

  def expect_cms_error(code)
    expect(response.status).to eq(DiscussionBridge::CmsProtocol::ERRORS.fetch(code).fetch("http"))
    expect(response.parsed_body).to eq("errors" => [code])
  end

  def native_models
    [
      DiscussionBridgeBridgeRecord,
      DiscussionBridgeContentBinding,
      DiscussionBridgeCmsSourceStream,
      DiscussionBridgeCmsSourceIntent,
      DiscussionBridgeCmsSourceRevision,
      DiscussionBridgeCmsSourceEvent,
      DiscussionBridgeCmsMapping,
      DiscussionBridgeCmsWork,
      DiscussionBridgeCmsMutationReceipt,
      DiscussionBridgeCmsUrlReservation,
      DiscussionBridgeCmsUrlMove,
      DiscussionBridgeCmsUrlHistoryEntry,
    ]
  end

  def audit_rows(mapping = nil)
    adapter = ActiveRecord::Base.connection
    where = mapping ? " WHERE cms_mapping_id = #{adapter.quote(mapping.id)}" : ""
    adapter.select_all(
      "SELECT * FROM discussion_bridge_cms_native_publication_events#{where} ORDER BY id",
    ).to_a.map do |row|
      row.merge("facts" => row["facts"].is_a?(String) ? JSON.parse(row["facts"]) : row["facts"])
    end
  end

  def counts
    native_models.to_h { |model| [model.table_name, model.count] }.merge("native_audit" => audit_rows.size)
  end

  def persisted_state
    native_models.to_h do |model|
      [model.table_name, model.order(:id).map { |row| row.attributes.deep_dup }]
    end.merge("native_audit" => audit_rows)
  end

  def policy
    @connection.reload.cms_configuration.fetch("policy")
  end

  def change_policy(changes)
    configuration = @connection.reload.cms_configuration.deep_dup
    configuration.fetch("policy").merge!(changes)
    @connection.update!(cms_configuration: configuration)
  end

  def source_revision(mapping)
    intent = DiscussionBridgeCmsSourceIntent.find_by!(
      source_id: mapping.source_id,
      current_source_revision: mapping.desired_source_revision,
    )
    intent.source_revisions.find_by!(source_revision: intent.current_source_revision)
  end

  def seed_retained_verified_state(mapping)
    # Synthetic RETAINED state, not CMS execution or proof-positive evidence.
    # NATIVE-01 already captured the actual immutable source and created this
    # mapping/work. No acknowledgement, URL finalize or fake verifier is called.
    work = mapping.work_items.order(:id).last
    captured = source_revision(mapping).source_metadata
    expect(work.source_snapshot).to eq(captured)
    work.update!(state: "verified", attempt: 1)
    mapping.update!(
      mapping_state: "active",
      destination_native_id: "fixture:article",
      destination_native_revision: "fixture:retained-native",
      synchronized_source_revision: work.source_revision,
      publicly_verified_source_revision: work.source_revision,
      synchronized_at: 2.minutes.ago,
      publicly_verified_at: 1.minute.ago,
      native_result: { "retained_fixture" => "private prior native state" },
      verified_result: { "retained_fixture" => "private prior verification state" },
    )
    work.reload
  end

  describe "NATIVE-01 publication" do
    it "does not substitute connection credentials for a native staff session" do
      before = counts
      publish(headers: @xhr_headers.merge(
        "X-DiscussionBridge-Connection" => @connection.public_id,
        "X-DiscussionBridge-Secret" => @secret,
      ))
      expect(response).to have_http_status(:forbidden)
      expect(counts).to eq(before)
    end

    it "denies a signed-in nonstaff caller before creating coupled state" do
      sign_in(user)
      before = counts
      publish
      expect(response).to have_http_status(:forbidden)
      expect(counts).to eq(before)
    end

    it "honors a native Guardian denial without defining a replacement visibility policy" do
      sign_in(moderator)
      before = counts
      # A denial-only boundary fixture avoids guessing Core private-topic role
      # rules. It tests delegation, not native Guardian policy qualification.
      allow_any_instance_of(Guardian).to receive(:can_see?).and_return(false)
      publish
      expect(response).to have_http_status(:forbidden)
      expect(counts).to eq(before)
    end

    it "creates one actual current source, mapping and pending work and resolves the same native identities" do
      sign_in(moderator)
      native_ids = [topic.id, first_post.id]
      native_counts = [Topic.count, Post.count]
      publish
      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body).to include(
        "outcome" => "created", "topic_id" => topic.id,
        "canonical_url" => "https://site.example/article/",
        "presentation_mode" => "simple", "publication_status" => "pending",
        "discussion_status" => "healthy",
      )
      record = DiscussionBridgeBridgeRecord.find_by!(resource_id: body.fetch("resource_id"))
      binding = record.active_binding("presentation")
      mapping = DiscussionBridgeCmsMapping.find_by!(content_binding_id: binding.id)
      intent = DiscussionBridgeCmsSourceIntent.find_by!(source_id: "topic:#{topic.id}")
      revision = intent.source_revisions.find_by!(source_revision: intent.current_source_revision)
      work = mapping.work_items.sole
      expect(intent.state).to eq("active")
      expect(mapping.source_id).to eq(intent.source_id)
      expect(mapping.desired_source_revision).to eq(revision.source_revision)
      expect(work).to have_attributes(
        action: "publish_revision", state: "pending", attempt: 0,
        policy_revision: policy.fetch("policy_revision"), source_revision: revision.source_revision,
      )
      expect(work.source_snapshot).to eq(revision.source_metadata)
      expect(binding).to have_attributes(
        content_connection_id: @connection.id, external_id: "article", presentation_mode: "simple",
      )
      receipt = DiscussionBridgeCmsMutationReceipt.order(:id).last
      expect(receipt.native_actor_user_id).to eq(moderator.id)
      stable = [record.id, record.resource_id, binding.id, mapping.id, mapping.mapping_id, work.id, revision.id]
      entity_counts = [DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count,
        DiscussionBridgeCmsMapping.count, DiscussionBridgeCmsWork.count, DiscussionBridgeCmsSourceRevision.count]

      publish
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("outcome" => "resolved", "resource_id" => record.resource_id)
      expect([record.reload.id, record.resource_id, binding.reload.id, mapping.reload.id,
        mapping.mapping_id, mapping.work_items.sole.id, source_revision(mapping).id]).to eq(stable)
      expect([DiscussionBridgeBridgeRecord.count, DiscussionBridgeContentBinding.count,
        DiscussionBridgeCmsMapping.count, DiscussionBridgeCmsWork.count, DiscussionBridgeCmsSourceRevision.count]).to eq(entity_counts)
      expect([topic.reload.id, first_post.reload.id]).to eq(native_ids)
      expect([Topic.count, Post.count]).to eq(native_counts)
    end

    {
      "lane" => [{ lane: "other" }, "scope_denied"],
      "presentation" => [{ presentation_mode: "full" }, "presentation_unsupported"],
      "destination" => [{ canonical_url: "https://other.example/article/" }, "scope_denied"],
    }.each do |label, (input, code)|
      it "does not let staff override the current #{label} selection using broader connection capabilities" do
        sign_in(admin)
        before = counts
        publish(input)
        expect_cms_error(code)
        expect(counts).to eq(before)
      end
    end

    it "does not publish a public topic excluded by current native policy" do
      change_policy("exclude_topic_ids" => [topic.id.to_s])
      sign_in(admin)
      before = counts
      publish
      expect_cms_error("source_ineligible")
      expect(counts).to eq(before)
    end

    it "stops at the native publisher gate without creating publication state" do
      SiteSetting.discussion_bridge_publisher_enabled = false
      sign_in(admin)
      before = counts
      publish
      expect(response).to have_http_status(:not_found)
      expect(counts).to eq(before)
    end

    it "rolls back source capture and all coupled rows when a later global URL guard fails" do
      retained = create_publication
      another, = issue_connection("Independent destination fixture")
      another_topic = Fabricate(:topic, user: admin)
      Fabricate(:post, topic: another_topic, user: admin, post_number: 1)
      before = persisted_state
      captured_id = nil
      allow(DiscussionBridge::CmsSourceLifecycle).to receive(:refresh).and_wrap_original do |original, *args, **options|
        result = original.call(*args, **options)
        if args[0].id == another.id && args[1] == another_topic.id
          captured_id = result.source_intent.id
          expect(result.source_intent).to be_persisted
        end
        result
      end
      publish({ external_id: "another" }, native_topic: another_topic, connection: another)
      expect_cms_error("url_collision")
      expect(captured_id).not_to be_nil
      expect(DiscussionBridgeCmsSourceIntent.exists?(captured_id)).to eq(false)
      expect(persisted_state).to eq(before)
      expect(retained.reload.content_binding.canonical_url).to eq("https://site.example/article/")
    end
  end

  it "rejects missing native CSRF proof for both mutations with the existing native protection enabled" do
    mapping = create_publication
    before = persisted_state
    previous = ApplicationController.allow_forgery_protection
    begin
      ApplicationController.allow_forgery_protection = true
      publish
      expect(response).to have_http_status(:forbidden)
      expect(persisted_state).to eq(before)
      correct(mapping, "https://site.example/moved/")
      expect(response).to have_http_status(:forbidden)
      expect(persisted_state).to eq(before)
    ensure
      ApplicationController.allow_forgery_protection = previous
    end
  end

  describe "native presentation mode status" do
    def select_mode_via_native_configuration(mode)
      configuration = @connection.reload.cms_configuration.deep_dup
      expected_revision = configuration.fetch("policy").delete("policy_revision")
      configuration.fetch("policy")["presentation_mode"] = mode
      put "/admin/content-connections/#{@connection.id}/cms-configuration.json",
          params: { expected_policy_revision: expected_revision, configuration: configuration },
          headers: @xhr_headers,
          as: :json
      expect(response).to have_http_status(:ok)
    end

    def publication_status(mapping)
      get "/admin/publishing/topics/#{topic.id}/status.json", headers: @xhr_headers
      expect(response).to have_http_status(:ok)
      response.parsed_body.fetch("publications").find do |publication|
        publication.fetch("resource_id") == mapping.content_binding.bridge_record.resource_id
      end
    end

    it "reports the current desired mode consistently with Mapping and preview without rewriting the initial binding" do
      mapping = create_publication
      binding = mapping.content_binding
      initial_binding = binding.attributes.deep_dup
      select_mode_via_native_configuration("full")
      before = persisted_state

      publication = publication_status(mapping)
      expect(publication).to include("presentation_mode" => "full", "initial_presentation_mode" => "simple")
      expect(publication.fetch("presentation_mode")).to eq(
        DiscussionBridge::CmsMappingProjection.call(mapping.reload).fetch("presentation_mode"),
      )
      get "/admin/content-connections/#{@connection.id}/cms-preview.json",
          params: { topic_id: topic.id.to_s }, headers: @xhr_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("presentation_mode")).to eq(publication.fetch("presentation_mode"))
      expect(binding.reload.attributes).to eq(initial_binding)
      expect(persisted_state).to eq(before)
      expect(publication).not_to have_key("applied_presentation_mode")
    end

    it "keeps completed delivery's retained policy distinct from a newly selected desired mode" do
      mapping = create_publication
      prior = seed_retained_verified_state(mapping)
      old_policy_revision = prior.policy_revision
      select_mode_via_native_configuration("full")
      expect(policy.fetch("policy_revision")).not_to eq(old_policy_revision)
      before = persisted_state

      publication = publication_status(mapping)
      expect(publication).to include("presentation_mode" => "full", "initial_presentation_mode" => "simple")
      expect(publication.fetch("delivery").fetch("work").fetch("policy_revision")).to eq(old_policy_revision)
      expect(publication.fetch("delivery").fetch("work").fetch("state")).to eq("verified")
      expect(publication).not_to have_key("applied_presentation_mode")
      expect(mapping.content_binding.reload.presentation_mode).to eq("simple")
      expect(persisted_state).to eq(before)
      # The fixture is retained native state, not execution of a CMS delivery or
      # proof that the new desired mode has been applied at its destination.
    end

    it "retains historical state and scope diagnostics when no validated current selection is available" do
      mapping = create_publication
      @connection.update!(enabled: false)
      before = persisted_state

      publication = publication_status(mapping)
      expect(publication).to include("presentation_mode" => nil, "initial_presentation_mode" => "simple")
      expect(publication.fetch("delivery").fetch("scope_issue")).to eq("connection_disabled")
      expect(mapping.content_binding.reload.presentation_mode).to eq("simple")
      expect(persisted_state).to eq(before)
    end
  end

  describe "NATIVE-02 presentation intention" do
    it "lets staff repeat the identical URL without writing publication, source, work or history" do
      mapping = create_publication
      seed_retained_verified_state(mapping)
      before = persisted_state
      configuration = @connection.reload.cms_configuration.deep_dup
      sign_in(moderator)
      correct(mapping, "https://site.example/article/")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "outcome" => "presentation_unchanged", "canonical_url" => "https://site.example/article/",
        "presentation_move_intent" => nil,
      )
      expect(persisted_state).to eq(before)
      expect(@connection.reload.cms_configuration).to eq(configuration)
    end

    it "requires native administrator authority for a different URL without broadening staff authority" do
      mapping = create_publication
      seed_retained_verified_state(mapping)
      before = persisted_state
      sign_in(moderator)
      correct(mapping, "https://site.example/moved/")
      expect(response).to have_http_status(:forbidden)
      expect(persisted_state).to eq(before)
    end

    it "records a private pending intention without inventing a verified cycle or changing the current URL" do
      mapping = create_publication
      work = mapping.work_items.sole
      previous_work = work.reload.attributes.deep_dup
      source_count = DiscussionBridgeCmsSourceRevision.count
      correct(mapping, "https://site.example/moved/")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "outcome" => "presentation_pending", "canonical_url" => "https://site.example/article/",
        "publication_status" => "pending",
      )
      safe_intent = response.parsed_body.fetch("presentation_move_intent")
      expect(safe_intent).to include("requested_url" => "https://site.example/moved/", "state" => "pending")
      expect(safe_intent.keys - %w[intent_id requested_url requested_at state work_id]).to be_empty
      expect(mapping.reload.work_items.count).to eq(1)
      expect(work.reload.attributes).to eq(previous_work)
      expect(DiscussionBridgeCmsSourceRevision.count).to eq(source_count)
      expect(DiscussionBridgeCmsUrlMove.count).to eq(0)
      expect(DiscussionBridgeCmsUrlHistoryEntry.count).to eq(0)
      expect(mapping.content_binding.reload.canonical_url).to eq("https://site.example/article/")
      expect(audit_rows(mapping).map { |event| event.fetch("event_kind") }).to eq(["presentation_move_intent"])
    end

    it "creates one audited eligible admin cycle while preserving prior verification, identities and history on replay" do
      mapping = create_publication
      prior = seed_retained_verified_state(mapping)
      prior_attributes = prior.attributes.deep_dup
      binding = mapping.content_binding
      record = binding.bridge_record
      stable = [record.id, record.resource_id, record.topic_id, binding.id, binding.external_id,
        binding.canonical_url, mapping.mapping_id, mapping.mapping_revision, mapping.source_id,
        mapping.destination_native_id, mapping.native_result.deep_dup, mapping.verified_result.deep_dup]
      configuration = @connection.reload.cms_configuration.deep_dup
      sources = DiscussionBridgeCmsSourceRevision.order(:id).map { |row| row.attributes.deep_dup }
      native_content = [topic.reload.attributes, first_post.reload.attributes]
      histories = DiscussionBridgeCmsUrlHistoryEntry.order(:id).map(&:attributes)

      correct(mapping, "https://site.example/moved/")
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include(
        "outcome" => "presentation_pending", "canonical_url" => "https://site.example/article/",
        "publication_status" => "pending", "discussion_status" => "healthy",
      )
      current = mapping.reload.work_items.order(:id).last
      expect(current.id).not_to eq(prior.id)
      expect(current.work_id).not_to eq(prior.work_id)
      expect(current.attempt_cycle).not_to eq(prior.attempt_cycle)
      expect(current).to have_attributes(
        action: "publish_revision", state: "pending", attempt: 0,
        source_revision: prior.source_revision, policy_revision: prior.policy_revision,
        source_snapshot: prior.source_snapshot,
      )
      intent = mapping.presentation_move_intent
      expect(intent).to include(
        "state" => "cycle_pending", "requested_url" => "https://site.example/moved/",
        "actor_user_id" => admin.id, "expected_mapping_revision" => mapping.mapping_revision,
        "prior_work_id" => prior.work_id, "work_id" => current.work_id,
      )
      events = audit_rows(mapping)
      expect(events.map { |event| event.fetch("event_kind") }).to eq(%w[url_publication_cycle presentation_move_intent])
      expect(events.map { |event| event.fetch("actor_user_id").to_i }.uniq).to eq([admin.id])
      expect(events.first.fetch("facts")).to include(
        "prior_work_id" => prior.work_id, "prior_attempt_cycle" => prior.attempt_cycle,
        "prior_attempt" => prior.attempt, "work_id" => current.work_id,
        "attempt_cycle" => current.attempt_cycle, "attempt" => 0,
        "source_revision" => prior.source_revision, "policy_revision" => prior.policy_revision,
      )
      expect(body.fetch("presentation_move_intent").keys - %w[intent_id requested_url requested_at state work_id]).to be_empty
      expect(response.body).not_to include("private prior native state", "private prior verification state", @secret, "lease_token")
      expect(prior.reload.attributes).to eq(prior_attributes)
      expect(@connection.reload.cms_configuration).to eq(configuration)
      expect(DiscussionBridgeCmsSourceRevision.order(:id).map(&:attributes)).to eq(sources)
      expect([topic.reload.attributes, first_post.reload.attributes]).to eq(native_content)
      expect(DiscussionBridgeCmsUrlHistoryEntry.order(:id).map(&:attributes)).to eq(histories)
      expect(DiscussionBridgeCmsUrlMove.count).to eq(0)
      expect([record.reload.id, record.resource_id, record.topic_id, binding.reload.id, binding.external_id,
        binding.canonical_url, mapping.mapping_id, mapping.mapping_revision, mapping.source_id,
        mapping.destination_native_id, mapping.native_result, mapping.verified_result]).to eq(stable)

      before_replay = persisted_state
      correct(mapping, "https://site.example/moved/")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("outcome" => "presentation_pending", "canonical_url" => binding.canonical_url)
      expect(persisted_state).to eq(before_replay)
      correct(mapping, "https://site.example/different/")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(persisted_state).to eq(before_replay)
    end

    it "does not create a new cycle from a retained verification of an older native source" do
      mapping = create_publication
      prior = seed_retained_verified_state(mapping)
      old_work = prior.attributes.deep_dup
      # Existing receiver fixture pattern: advance native raw/cooked/version/time
      # without running the asynchronous source refresh job.
      first_post.update_columns(
        raw: "A changed native source", cooked: "<p>A changed native source</p>",
        version: first_post.version + 1, updated_at: Time.current + 10,
      )
      revisions = DiscussionBridgeCmsSourceRevision.count
      correct(mapping, "https://site.example/moved/")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("outcome")).to eq("presentation_pending")
      expect(mapping.reload.presentation_move_intent).to include("state" => "attention", "attention_code" => "revision_conflict")
      expect(mapping.work_items.count).to eq(1)
      expect(prior.reload.attributes).to eq(old_work)
      expect(DiscussionBridgeCmsSourceRevision.count).to eq(revisions)
      expect(mapping.content_binding.reload.canonical_url).to eq("https://site.example/article/")
      expect(audit_rows(mapping).map { |event| event.fetch("event_kind") }).not_to include("url_publication_cycle")
    end

    it "does not manufacture a fresh cycle when the current policy differs from the retained verified work" do
      mapping = create_publication
      prior = seed_retained_verified_state(mapping)
      old_work = prior.attributes.deep_dup
      change_policy("policy_revision" => SecureRandom.uuid)
      current_policy = policy.deep_dup
      correct(mapping, "https://site.example/moved/")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("outcome")).to eq("presentation_pending")
      expect(mapping.reload.presentation_move_intent.fetch("state")).not_to eq("cycle_pending")
      expect(mapping.work_items.count).to eq(1)
      expect(prior.reload.attributes).to eq(old_work)
      expect(policy).to eq(current_policy)
      expect(mapping.content_binding.reload.canonical_url).to eq("https://site.example/article/")
      expect(audit_rows(mapping).map { |event| event.fetch("event_kind") }).not_to include("url_publication_cycle")
    end

    it "rejects a globally owned destination URL without changing either publication or creating an admin cycle" do
      mapping = create_publication
      seed_retained_verified_state(mapping)
      another, = issue_connection("Other native publisher destination")
      another_topic = Fabricate(:topic, user: admin)
      Fabricate(:post, topic: another_topic, user: admin, post_number: 1)
      publish({ external_id: "other", canonical_url: "https://site.example/taken/" },
        native_topic: another_topic, connection: another)
      expect(response).to have_http_status(:created)
      before = persisted_state
      correct(mapping, "https://site.example/taken/")
      expect_cms_error("url_collision")
      expect(persisted_state).to eq(before)
    end
  end
end
