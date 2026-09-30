# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge Adapter Protocol Alpha.21 publication work" do
  include ActiveSupport::Testing::TimeHelpers

  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Alpha.21 work WordPress",
      platform: "wordpress",
      allowed_origins: ["https://publisher.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: ["articles"],
      destination_policies: [destination_policy],
      catalog_required: true,
      policy_revision: "policy:2026-09-27:4",
    )
  end

  def destination_policy(catalog_revision: "catalog:wordpress:2026-09-27:1")
    {
      "destination_policy_id" => "destination:wordpress:articles:1",
      "profile" => "wordpress",
      "presentation_mode" => "interactive",
      "container_mapping" => {
        "source" => "discourse:category:articles",
        "destination" => "site:articles",
      },
      "taxonomy_mapping" => { "mode" => "mapped_only" },
      "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => {
        "maximum_bytes" => 49_152,
        "overflow_behavior" => "excerpt_with_read_more",
      },
      "catalog_revision" => catalog_revision,
    }
  end

  def headers(correlation:)
    {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => DiscussionBridge::CONTRACT_VERSION,
      "X-DiscussionBridge-Correlation" => correlation,
      "HTTPS" => "on",
    }
  end

  def catalog_segments(authors: [{ "id" => "author:editor", "name" => "Editor", "available" => true }])
    [
      {
        "segment_type" => "containers",
        "items" => [
          { "id" => "site:articles", "name" => "Articles", "kind" => "post_type", "available" => true },
        ],
      },
      {
        "segment_type" => "taxonomies",
        "items" => [
          { "id" => "site:categories", "name" => "Categories", "hierarchical" => true, "available" => true },
        ],
      },
      { "segment_type" => "terms", "items" => [] },
      { "segment_type" => "authors", "items" => authors },
      {
        "segment_type" => "presentation_modes",
        "items" => [
          { "id" => "interactive", "name" => "Interactive", "available" => true },
        ],
      },
      {
        "segment_type" => "native_limits",
        "items" => [
          {
            "id" => "wordpress:post-content",
            "name" => "WordPress post content",
            "maximum_bytes" => 49_152,
            "overflow_behavior" => "excerpt_with_read_more",
            "available" => true,
          },
        ],
      },
    ]
  end

  def install_catalog(authors: [{ "id" => "author:editor", "name" => "Editor", "available" => true }])
    correlation = "catalog-install-1"
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: correlation),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: destination_policy.fetch("catalog_revision"),
          segments: catalog_segments(authors: authors),
          correlation_id: correlation,
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    revision = response.parsed_body.fetch("catalog_revision")
    @connection.update!(destination_policies: [destination_policy(catalog_revision: revision)])
    revision
  end

  def make_destination_static!
    policy = @connection.destination_policies.sole.deep_stringify_keys
    policy["profile"] = "astro"
    @connection.platform_catalogs.update_all(platform_profile: "astro")
    @connection.update!(platform: "astro", destination_policies: [policy])
  end

  def create_source(content: "<p>Publication body</p>", title: "Publication source")
    topic = Fabricate(:topic, user: admin, category: category, title: title, visible: true)
    post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "Publication body")
    post.update_columns(cooked: content)
    result = DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: @connection.id,
      topic_id: topic.id,
      external_id: "page-#{SecureRandom.hex(4)}",
      canonical_url: "https://publisher.example/articles/#{SecureRandom.hex(4)}/",
      lane: "articles",
      native_materialization: true,
    )
    [topic, post, result.record]
  end

  def materialize_source
    get "/discussion-bridge/v1/source-topics.json",
        headers: headers(correlation: "source-materialize-1")
    expect(response).to have_http_status(:ok), response.body
  end

  def claim(correlation: "claim-1", maximum_items: 1, lease_seconds: 300)
    post "/discussion-bridge/v1/publication-work/claim.json",
         headers: headers(correlation: correlation),
         params: {
           worker_id: "worker-1",
           maximum_items: maximum_items,
           requested_lease_seconds: lease_seconds,
           correlation_id: correlation,
         },
         as: :json
  end

  def acknowledgement(claimed, record, correlation:, deployment_state: "not_required",
                      verification_state: "not_required", stage: "synchronized", stage_token: nil,
                      synchronized_at: Time.zone.now.iso8601(6), **extra)
    {
      lease_token: claimed.fetch("lease_token"),
      resource_id: record.resource_id,
      source_revision: claimed.fetch("source_revision"),
      source_revision_sequence: claimed.fetch("source_revision_sequence"),
      policy_revision: claimed.fetch("policy_revision"),
      destination_policy_id: claimed.fetch("destination_policy_id"),
      action: claimed.fetch("action"),
      stage: stage,
      stage_token: stage_token || claimed.fetch("stage_token"),
      destination_binding: {
        binding_id: record.active_binding("presentation").binding_id,
        external_id: record.active_binding("presentation").external_id,
        canonical_url: record.active_binding("presentation").canonical_url,
        publication_revision: "wordpress:post:revision:1",
        content_disposition: "complete",
      },
      synchronized_at: synchronized_at,
      deployment_state: deployment_state,
      verification_state: verification_state,
      correlation_id: correlation,
    }.merge(extra)
  end

  it "stores immutable descriptive catalog revisions without granting authority" do
    initial_directions = @connection.allowed_directions
    revision = install_catalog
    expect(@connection.reload.allowed_directions).to eq(initial_directions)
    expect(@connection.publication_works).to be_empty

    get "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: "catalog-show-1"),
        params: {
          platform_profile: "wordpress",
          segment_type: "authors",
          catalog_revision: revision,
          limit: 1,
        }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.keys).to contain_exactly(
      *DiscussionBridge::PlatformCatalogProtocol::RESPONSE_FIELDS,
    )
    expect(response.parsed_body).to include(
      "catalog_revision" => revision,
      "complete" => true,
    )
    expect(response.headers["Cache-Control"]).to include("private", "must-revalidate")

    stale = "catalog-stale-1"
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: stale),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: destination_policy.fetch("catalog_revision"),
          segments: catalog_segments,
          correlation_id: stale,
        },
        as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("catalog_revision_conflict")
  end

  it "retains a removed policy-referenced catalog item as unavailable" do
    revision = install_catalog
    correlation = "catalog-remove-1"
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: correlation),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: revision,
          segments: [{ "segment_type" => "containers", "items" => [] }],
          correlation_id: correlation,
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    next_revision = response.parsed_body.fetch("catalog_revision")

    get "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: "catalog-remove-show"),
        params: {
          platform_profile: "wordpress",
          segment_type: "containers",
          catalog_revision: next_revision,
        }
    expect(response.parsed_body.fetch("items").sole).to include(
      "id" => "site:articles",
      "available" => false,
    )
  end

  it "binds a signed catalog cursor to its requested segment" do
    revision = install_catalog(
      authors: [
        { "id" => "author:editor", "name" => "Editor", "available" => true },
        { "id" => "author:writer", "name" => "Writer", "available" => true },
      ],
    )
    get "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: "catalog-cursor-authors"),
        params: {
          platform_profile: "wordpress",
          segment_type: "authors",
          catalog_revision: revision,
          limit: 1,
        }
    expect(response).to have_http_status(:ok), response.body
    cursor = response.parsed_body.fetch("next_cursor")

    get "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: "catalog-cursor-containers"),
        params: {
          platform_profile: "wordpress",
          segment_type: "containers",
          catalog_revision: revision,
          cursor: cursor,
          limit: 1,
        }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("cursor_snapshot_mismatch")
  end

  it "claims exact resolved work, renews its bounded lease, and completes a dynamic destination" do
    install_catalog
    _, _, record = create_source
    materialize_source

    claim
    expect(response).to have_http_status(:ok), response.body
    claimed = response.parsed_body.fetch("publication_work").sole
    expect(claimed.keys).to contain_exactly(*DiscussionBridge::PublicationWorkProtocol::WORK_FIELDS)
    expect(claimed).to include(
      "resource_id" => record.resource_id,
      "action" => "publish",
      "attempt_count" => 1,
      "retry_generation" => 0,
      "resolved_container" => { "id" => "site:articles", "kind" => "post_type" },
    )

    renew_correlation = "renew-1"
    post "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/renew.json",
         headers: headers(correlation: renew_correlation),
         params: {
           lease_token: claimed.fetch("lease_token"),
           requested_lease_seconds: 60,
           correlation_id: renew_correlation,
         },
         as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("total_lease_seconds")).to eq(360)

    forged_static_correlation = "ack-dynamic-forged-static"
    forged_static = acknowledgement(
      claimed,
      record,
      correlation: forged_static_correlation,
      deployment_state: "pending",
      verification_state: "pending",
    )
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: forged_static_correlation),
        params: forged_static,
        as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("stage_conflict")

    ack_correlation = "ack-dynamic-1"
    body = acknowledgement(claimed, record, correlation: ack_correlation)
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: ack_correlation),
        params: body,
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      "accepted_stage" => "synchronized",
      "resulting_state" => "acknowledged",
      "terminal" => true,
    )
    expect(DiscussionBridgePublicationWork.find_by!(work_id: claimed.fetch("work_id")).state).to eq("acknowledged")
    expect(record.active_binding("presentation").reload).to have_attributes(
      applied_source_revision: claimed.fetch("source_revision"),
      publication_revision: "wordpress:post:revision:1",
      deployment_state: "not_required",
      verification_state: "not_required",
    )

    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: ack_correlation),
        params: body,
        as: :json
    expect(response).to have_http_status(:ok)
    expect(DiscussionBridgePublicationAcknowledgement.count).to eq(1)
  end

  it "rotates exact static stage tokens and rejects changed replay" do
    install_catalog
    make_destination_static!
    _, _, record = create_source
    materialize_source
    claim(correlation: "static-claim")
    claimed = response.parsed_body.fetch("publication_work").sole
    dynamic_policy = @connection.destination_policies.sole.deep_stringify_keys
    dynamic_policy["profile"] = "wordpress"
    @connection.update!(platform: "wordpress", destination_policies: [dynamic_policy])
    synchronized_at = Time.zone.now.iso8601(6)

    forged_dynamic_correlation = "static-forged-dynamic"
    forged_dynamic = acknowledgement(
      claimed,
      record,
      correlation: forged_dynamic_correlation,
      synchronized_at: synchronized_at,
    )
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: forged_dynamic_correlation), params: forged_dynamic, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("stage_conflict")

    sync_correlation = "static-sync"
    sync = acknowledgement(
      claimed,
      record,
      correlation: sync_correlation,
      deployment_state: "pending",
      verification_state: "pending",
      synchronized_at: synchronized_at,
    )
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: sync_correlation), params: sync, as: :json
    expect(response).to have_http_status(:ok), response.body
    deployed_token = response.parsed_body.fetch("next_stage_token")
    expect(response.parsed_body.fetch("resulting_state")).to eq("awaiting_deployment")

    changed = sync.deep_dup
    changed[:destination_binding][:publication_revision] = "changed"
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: sync_correlation), params: changed, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("stage_conflict")

    deployed_at = 1.second.from_now.iso8601(6)
    deployed_correlation = "static-deployed"
    deployed = acknowledgement(
      claimed,
      record,
      correlation: deployed_correlation,
      stage: "deployed",
      stage_token: deployed_token,
      deployment_state: "deployed",
      verification_state: "pending",
      synchronized_at: synchronized_at,
      deployed_at: deployed_at,
    )
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: deployed_correlation), params: deployed, as: :json
    expect(response).to have_http_status(:ok), response.body
    verified_token = response.parsed_body.fetch("next_stage_token")

    verified_correlation = "static-verified"
    verified = acknowledgement(
      claimed,
      record,
      correlation: verified_correlation,
      stage: "verified",
      stage_token: verified_token,
      deployment_state: "deployed",
      verification_state: "verified",
      synchronized_at: synchronized_at,
      deployed_at: deployed_at,
      publicly_verified_at: 2.seconds.from_now.iso8601(6),
    )
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: verified_correlation), params: verified, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("resulting_state" => "acknowledged", "terminal" => true)
    work = DiscussionBridgePublicationWork.find_by!(work_id: claimed.fetch("work_id"))
    expect(work).to have_attributes(
      static_deployment: true,
      synchronized_at_wire: synchronized_at,
      deployed_at_wire: deployed_at,
      publicly_verified_at_wire: verified.fetch(:publicly_verified_at),
    )
    expect(record.active_binding("presentation").reload).to have_attributes(
      synchronized_at_wire: synchronized_at,
      deployed_at_wire: deployed_at,
      publicly_verified_at_wire: verified.fetch(:publicly_verified_at),
    )
  end

  it "retains and delivers server-created withdrawal work after the connection is disabled" do
    install_catalog
    _, _, record = create_source
    materialize_source
    claim(correlation: "disable-withdrawal-publish")
    published = response.parsed_body.fetch("publication_work").sole
    put "/discussion-bridge/v1/publication-work/#{published.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "disable-withdrawal-published"),
        params: acknowledgement(published, record, correlation: "disable-withdrawal-published"),
        as: :json
    expect(response).to have_http_status(:ok), response.body

    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: { content_connection: { enabled: false } },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    sign_out

    withdrawal = @connection.publication_works.where(action: "unpublish").sole
    expect(withdrawal).to have_attributes(
      source_revocation_id: be_present,
      destination_policy_id: published.fetch("destination_policy_id"),
      state: "available",
    )
    claim(correlation: "disable-withdrawal-claim")
    expect(response).to have_http_status(:ok), response.body
    claimed_withdrawal = response.parsed_body.fetch("publication_work").sole
    expect(claimed_withdrawal).to include(
      "work_id" => withdrawal.work_id,
      "action" => "unpublish",
    )

    last_seen_at = @connection.reload.last_seen_at
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json",
        headers: headers(correlation: "invalid-withdrawal-record").merge(
          "X-DiscussionBridge-Secret" => "invalid-secret",
        )
    expect(response).to have_http_status(:unauthorized)
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json",
        headers: headers(correlation: "disabled-withdrawal-record")
    expect(response).to have_http_status(:ok), response.body
    cleanup_record = response.parsed_body.fetch("bridge_record")
    expect(cleanup_record).to include(
      "resource_id" => record.resource_id,
      "source_revision" => claimed_withdrawal.fetch("source_revision"),
      "source_revision_sequence" => claimed_withdrawal.fetch("source_revision_sequence"),
    )
    expect(cleanup_record).not_to have_key("content_transport")
    expect(@connection.reload.last_seen_at).to eq_time(last_seen_at)

    get "/discussion-bridge/v1/connection.json", headers: headers(correlation: "disabled-capability")
    expect(response).to have_http_status(:unauthorized)
  end

  it "withdraws an issued destination when a platform change removes its sole policy" do
    install_catalog
    _, source_post, record = create_source
    materialize_source
    claim(correlation: "policy-removal-publish")
    published = response.parsed_body.fetch("publication_work").sole
    put "/discussion-bridge/v1/publication-work/#{published.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "policy-removal-published"),
        params: acknowledgement(published, record, correlation: "policy-removal-published"),
        as: :json
    expect(response).to have_http_status(:ok), response.body

    source_post.update_columns(
      cooked: "<p>Queued but not issued update</p>",
      updated_at: 1.minute.from_now,
    )
    DiscussionBridge::SourceRevisionMaterializer.call(
      record: record,
      connection: @connection,
      force_revision: true,
    )
    queued = @connection.publication_works.order(:id).last
    expect(queued).to have_attributes(action: "update", state: "available", leased_at: nil)
    queued.update_columns(resolved_container: { "id" => "site:queued-only", "kind" => "post_type" })

    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: {
          content_connection: {
            platform: "ghost",
            allowed_directions: ["from_discourse"],
          },
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    sign_out

    expect(DiscussionBridge::ConnectionCapability.publication_active?(@connection.reload)).to be(false)
    withdrawal = @connection.publication_works.where(action: "unpublish").sole
    expect(withdrawal).to have_attributes(
      destination_policy_id: published.fetch("destination_policy_id"),
      policy_revision: published.fetch("policy_revision"),
      source_revocation_id: be_present,
      state: "available",
    )
    expect(withdrawal.resolved_container).to eq(
      DiscussionBridgePublicationWork.find_by!(work_id: published.fetch("work_id")).resolved_container,
    )
    expect(withdrawal.resolved_container).not_to eq(queued.reload.resolved_container)

    claim(correlation: "policy-removal-withdrawal")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("publication_work").sole).to include(
      "work_id" => withdrawal.work_id,
      "action" => "unpublish",
      "destination_policy_id" => published.fetch("destination_policy_id"),
    )
  end

  it "keeps one removed policy withdrawable while an unchanged policy continues" do
    install_catalog
    policy_a = @connection.destination_policies.sole.deep_stringify_keys
    policy_b = policy_a.merge("destination_policy_id" => "destination:wordpress:articles:2")
    @connection.update!(
      destination_policies: [policy_a, policy_b],
      policy_revision: "policy:two-destinations:1",
    )
    _, _, record = create_source
    materialize_source
    published = 2.times.map do |index|
      claim(correlation: "multi-policy-publish-#{index}")
      item = response.parsed_body.fetch("publication_work").sole
      correlation = "multi-policy-published-#{index}"
      put "/discussion-bridge/v1/publication-work/#{item.fetch("work_id")}/acknowledgement.json",
          headers: headers(correlation: correlation),
          params: acknowledgement(item, record, correlation: correlation),
          as: :json
      expect(response).to have_http_status(:ok), response.body
      item
    end
    expect(published.map { |item| item.fetch("destination_policy_id") }).to contain_exactly(
      policy_a.fetch("destination_policy_id"),
      policy_b.fetch("destination_policy_id"),
    )

    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: { content_connection: { publication_policy: policy_b } },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    sign_out

    DiscussionBridge::SourceRevocationRegistry.reconcile_record!(
      record: record,
      connection: @connection.reload,
    )
    withdrawal = @connection.publication_works.where(action: "unpublish").sole
    expect(withdrawal.destination_policy_id).to eq(policy_a.fetch("destination_policy_id"))
    expect(withdrawal.source_revocation_record.reload.restored_at).to be_present

    claim(correlation: "multi-policy-withdrawal")
    claimed = response.parsed_body.fetch("publication_work").sole
    expect(claimed).to include(
      "work_id" => withdrawal.work_id,
      "action" => "unpublish",
      "destination_policy_id" => policy_a.fetch("destination_policy_id"),
    )
  end

  it "retries persisted withdrawal work after From Discourse direction removal" do
    install_catalog
    _, _, record = create_source
    materialize_source
    claim(correlation: "direction-removal-publish")
    published = response.parsed_body.fetch("publication_work").sole
    put "/discussion-bridge/v1/publication-work/#{published.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "direction-removal-published"),
        params: acknowledgement(published, record, correlation: "direction-removal-published"),
        as: :json
    expect(response).to have_http_status(:ok), response.body

    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: { content_connection: { allowed_directions: ["to_discourse"] } },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    sign_out

    expect(@connection.reload.allows_direction?("from_discourse")).to be(false)
    claim(correlation: "direction-removal-withdrawal")
    withdrawn = response.parsed_body.fetch("publication_work").sole
    expect(withdrawn.fetch("action")).to eq("unpublish")
    put "/discussion-bridge/v1/publication-work/#{withdrawn.fetch("work_id")}/failure.json",
        headers: headers(correlation: "direction-removal-failure"),
        params: {
          lease_token: withdrawn.fetch("lease_token"),
          error_code: "destination_unavailable",
          error_detail: "Destination temporarily unavailable during withdrawal",
          failed_at: Time.zone.now.iso8601(6),
          correlation_id: "direction-removal-failure",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("resulting_state")).to eq("retry_wait")

    travel_to(61.seconds.from_now) do
      claim(correlation: "direction-removal-restart")
      retried = response.parsed_body.fetch("publication_work").sole
      expect(retried).to include(
        "work_id" => withdrawn.fetch("work_id"),
        "action" => "unpublish",
        "attempt_count" => 2,
      )
      put "/discussion-bridge/v1/publication-work/#{retried.fetch("work_id")}/acknowledgement.json",
          headers: headers(correlation: "direction-removal-complete"),
          params: acknowledgement(retried, record, correlation: "direction-removal-complete"),
          as: :json
      expect(response).to have_http_status(:ok), response.body
    end
  end

  it "does not supersede an unexpired post-sync static lease when a newer revision arrives" do
    install_catalog
    make_destination_static!
    topic, post, record = create_source
    materialize_source
    claim(correlation: "serialize-static-initial", lease_seconds: 300)
    initial = response.parsed_body.fetch("publication_work").sole
    synchronized = acknowledgement(
      initial,
      record,
      correlation: "serialize-static-sync",
      deployment_state: "pending",
      verification_state: "pending",
    )
    put "/discussion-bridge/v1/publication-work/#{initial.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "serialize-static-sync"),
        params: synchronized,
        as: :json
    expect(response).to have_http_status(:ok), response.body
    active = DiscussionBridgePublicationWork.find_by!(work_id: initial.fetch("work_id"))
    expect(active.state).to eq("awaiting_deployment")

    post.update_columns(
      raw: "Newer publication body",
      cooked: "<p>Newer publication body</p>",
      version: post.version + 1,
      updated_at: 1.minute.from_now,
    )
    DiscussionBridge::SourceRevisionMaterializer.call(
      record: record,
      connection: @connection,
      force_revision: true,
    )

    expect(active.reload.state).to eq("awaiting_deployment")
    expect(@connection.publication_works.where(state: "available").count).to eq(1)
    claim(correlation: "serialize-static-blocked")
    expect(response.parsed_body.fetch("publication_work")).to be_empty
    expect(topic.reload.id).to eq(record.topic_id)
  end

  it "rechecks publication authority under the connection lock before issuing a claim" do
    install_catalog
    create_source
    materialize_source
    checks = 0
    allow_any_instance_of(DiscussionBridge::PublicationWorkRegistry).to receive(
      :currently_authorized?,
    ).and_wrap_original do |original, work, **options|
      checks += 1
      if checks == 1
        @connection.update_columns(enabled: false)
        true
      else
        original.call(work, **options)
      end
    end

    claim(correlation: "authority-race-claim")

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("publication_work")).to be_empty
    work = @connection.publication_works.sole.reload
    expect(work).to have_attributes(state: "available", leased_at: nil, may_have_materialized: false)
  end

  it "retains durable cleanup evidence after an issued lease expires and resets" do
    install_catalog
    _, _, record = create_source
    materialize_source
    claim(correlation: "issued-before-expiry", lease_seconds: 1)
    issued = DiscussionBridgePublicationWork.find_by!(
      work_id: response.parsed_body.fetch("publication_work").sole.fetch("work_id"),
    )
    expect(issued.may_have_materialized).to be(true)

    travel_to(2.seconds.from_now) do
      DiscussionBridge::PublicationWorkRegistry.new(connection: @connection).send(
        :reconcile_expired!,
        Time.zone.now,
      )
      expect(issued.reload).to have_attributes(state: "available", leased_at: nil, may_have_materialized: true)

      sign_in(admin)
      put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
          params: { content_connection: { enabled: false } },
          as: :json
      expect(response).to have_http_status(:ok), response.body
      sign_out
    end

    withdrawal = @connection.publication_works.where(action: "unpublish").sole
    expect(withdrawal).to have_attributes(
      bridge_record_id: record.id,
      destination_policy_id: issued.destination_policy_id,
      state: "available",
    )
  end

  it "resumes retryable static work from its last acknowledged stage" do
    install_catalog
    make_destination_static!
    _, _, record = create_source
    materialize_source
    claim(correlation: "resume-static-initial")
    initial_claim = response.parsed_body.fetch("publication_work").sole
    synchronized_at = Time.zone.now.iso8601(6)
    synchronized = acknowledgement(
      initial_claim,
      record,
      correlation: "resume-static-synchronized",
      deployment_state: "pending",
      verification_state: "pending",
      synchronized_at: synchronized_at,
    )
    put "/discussion-bridge/v1/publication-work/#{initial_claim.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "resume-static-synchronized"),
        params: synchronized,
        as: :json
    expect(response).to have_http_status(:ok), response.body

    put "/discussion-bridge/v1/publication-work/#{initial_claim.fetch("work_id")}/failure.json",
        headers: headers(correlation: "resume-static-deploy-failure"),
        params: {
          lease_token: initial_claim.fetch("lease_token"),
          error_code: "deploy_failed",
          error_detail: "Static deployment failed before completion.",
          failed_at: Time.zone.now.iso8601(6),
          correlation_id: "resume-static-deploy-failure",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    work = DiscussionBridgePublicationWork.find_by!(work_id: initial_claim.fetch("work_id"))
    expect(work).to have_attributes(state: "retry_wait", last_acknowledged_stage: "synchronized")

    travel_to(work.next_retry_at + 1.second)
    claim(correlation: "resume-static-deploy-claim")
    deploy_claim = response.parsed_body.fetch("publication_work").sole
    expect(deploy_claim).to include(
      "work_id" => initial_claim.fetch("work_id"),
      "attempt_count" => 2,
    )
    expect(deploy_claim.fetch("lease_token")).not_to eq(initial_claim.fetch("lease_token"))
    expect(deploy_claim.fetch("stage_token")).not_to eq(initial_claim.fetch("stage_token"))
    expect(work.reload).to have_attributes(
      state: "awaiting_deployment",
      last_acknowledged_stage: "synchronized",
    )

    repeated_synchronized = acknowledgement(
      deploy_claim,
      record,
      correlation: "resume-static-repeat-synchronized",
      deployment_state: "pending",
      verification_state: "pending",
      synchronized_at: synchronized_at,
    )
    put "/discussion-bridge/v1/publication-work/#{deploy_claim.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "resume-static-repeat-synchronized"),
        params: repeated_synchronized,
        as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("stage_conflict")

    deployed_at = Time.zone.now.iso8601(6)
    deployed = acknowledgement(
      deploy_claim,
      record,
      correlation: "resume-static-deployed",
      stage: "deployed",
      deployment_state: "deployed",
      verification_state: "pending",
      synchronized_at: synchronized_at,
      deployed_at: deployed_at,
    )
    put "/discussion-bridge/v1/publication-work/#{deploy_claim.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "resume-static-deployed"),
        params: deployed,
        as: :json
    expect(response).to have_http_status(:ok), response.body

    put "/discussion-bridge/v1/publication-work/#{deploy_claim.fetch("work_id")}/failure.json",
        headers: headers(correlation: "resume-static-verification-failure"),
        params: {
          lease_token: deploy_claim.fetch("lease_token"),
          error_code: "public_verification_failed",
          error_detail: "Public verification did not complete.",
          failed_at: Time.zone.now.iso8601(6),
          correlation_id: "resume-static-verification-failure",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    work.reload
    expect(work).to have_attributes(state: "retry_wait", last_acknowledged_stage: "deployed")

    travel_to(work.next_retry_at + 1.second)
    claim(correlation: "resume-static-verification-claim")
    verification_claim = response.parsed_body.fetch("publication_work").sole
    expect(verification_claim).to include(
      "work_id" => initial_claim.fetch("work_id"),
      "attempt_count" => 3,
    )
    expect(verification_claim.fetch("lease_token")).not_to eq(deploy_claim.fetch("lease_token"))
    expect(verification_claim.fetch("stage_token")).not_to eq(deploy_claim.fetch("stage_token"))
    expect(work.reload).to have_attributes(
      state: "awaiting_verification",
      last_acknowledged_stage: "deployed",
    )

    verified = acknowledgement(
      verification_claim,
      record,
      correlation: "resume-static-verified",
      stage: "verified",
      deployment_state: "deployed",
      verification_state: "verified",
      synchronized_at: synchronized_at,
      deployed_at: deployed_at,
      publicly_verified_at: Time.zone.now.iso8601(6),
    )
    put "/discussion-bridge/v1/publication-work/#{verification_claim.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "resume-static-verified"),
        params: verified,
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("resulting_state" => "acknowledged", "terminal" => true)
    expect(work.reload).to have_attributes(state: "acknowledged", last_acknowledged_stage: "verified")
  end

  it "reclaims expired post-sync static work without repeating synchronization" do
    install_catalog
    make_destination_static!
    _, _, record = create_source
    materialize_source
    claim(correlation: "expired-static-initial", lease_seconds: 60)
    initial = response.parsed_body.fetch("publication_work").sole
    synchronized_at = Time.zone.now.iso8601(9)
    synchronized = acknowledgement(
      initial,
      record,
      correlation: "expired-static-synchronized",
      deployment_state: "pending",
      verification_state: "pending",
      synchronized_at: synchronized_at,
    )
    put "/discussion-bridge/v1/publication-work/#{initial.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "expired-static-synchronized"),
        params: synchronized,
        as: :json
    expect(response).to have_http_status(:ok), response.body
    work = DiscussionBridgePublicationWork.find_by!(work_id: initial.fetch("work_id"))
    expect(work).to have_attributes(state: "awaiting_deployment", last_acknowledged_stage: "synchronized")

    travel_to(work.lease_expires_at + 1.second)
    claim(correlation: "expired-static-reclaim", lease_seconds: 60)
    reclaimed = response.parsed_body.fetch("publication_work").sole
    expect(reclaimed).to include("work_id" => initial.fetch("work_id"), "attempt_count" => 1)
    expect(reclaimed.fetch("lease_token")).not_to eq(initial.fetch("lease_token"))
    expect(reclaimed.fetch("stage_token")).not_to eq(initial.fetch("stage_token"))
    expect(work.reload).to have_attributes(
      state: "awaiting_deployment",
      last_acknowledged_stage: "synchronized",
      synchronized_at_wire: synchronized_at,
    )

    repeated = acknowledgement(
      reclaimed,
      record,
      correlation: "expired-static-repeat-sync",
      deployment_state: "pending",
      verification_state: "pending",
      synchronized_at: synchronized_at,
    )
    put "/discussion-bridge/v1/publication-work/#{reclaimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "expired-static-repeat-sync"), params: repeated, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("stage_conflict")
  end

  it "applies the exact retry schedule, exhaustion, and authorized manual retry generation" do
    install_catalog
    create_source
    materialize_source

    1.upto(4) do |attempt|
      claim(correlation: "retry-claim-#{attempt}")
      claimed = response.parsed_body.fetch("publication_work").sole
      expect(claimed.fetch("attempt_count")).to eq(attempt)
      correlation = "retry-failure-#{attempt}"
      put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/failure.json",
          headers: headers(correlation: correlation),
          params: {
            lease_token: claimed.fetch("lease_token"),
            error_code: "destination_unavailable",
            error_detail: "Destination returned a temporary unavailable response.",
            failed_at: Time.zone.now.iso8601(6),
            correlation_id: correlation,
          },
          as: :json
      expect(response).to have_http_status(:ok), response.body
      work = DiscussionBridgePublicationWork.find_by!(work_id: claimed.fetch("work_id"))
      if attempt < 4
        expect(work.state).to eq("retry_wait")
        travel_to(work.next_retry_at + 1.second)
      else
        expect(work.state).to eq("operator_attention")
        DiscussionBridge::PublicationWorkRegistry.manual_retry!(
          work: work,
          authorized_by: admin,
          condition_corrected: true,
        )
        expect(work.reload).to have_attributes(
          state: "available",
          attempt_count: 1,
          retry_generation: 1,
        )
      end
    end
  end

  it "serializes a newer revision behind an active lease and rejects its late acknowledgement" do
    install_catalog
    _, source_post, record = create_source
    materialize_source
    claim(correlation: "supersession-old", lease_seconds: 60)
    old_claim = response.parsed_body.fetch("publication_work").sole

    source_post.update_columns(cooked: "<p>New revision</p>", updated_at: 1.minute.from_now)
    get "/discussion-bridge/v1/source-topics.json",
        headers: headers(correlation: "supersession-materialize")
    expect(response).to have_http_status(:ok), response.body

    claim(correlation: "supersession-blocked")
    expect(response.parsed_body.fetch("publication_work")).to be_empty

    travel_to(DiscussionBridgePublicationWork.find_by!(work_id: old_claim.fetch("work_id")).lease_expires_at + 1.second)
    claim(correlation: "supersession-new")
    new_claim = response.parsed_body.fetch("publication_work").sole
    expect(new_claim.fetch("source_revision_sequence")).to be > old_claim.fetch("source_revision_sequence")
    expect(DiscussionBridgePublicationWork.find_by!(work_id: old_claim.fetch("work_id")).state).to eq("superseded")

    correlation = "supersession-late"
    late = acknowledgement(old_claim, record, correlation: correlation)
    put "/discussion-bridge/v1/publication-work/#{old_claim.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: correlation), params: late, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("work_superseded")
  end

  it "rejects renewal and acknowledgement after current scope narrows" do
    install_catalog
    _, _, record = create_source
    materialize_source
    claim(correlation: "scope-narrowing-claim")
    claimed = response.parsed_body.fetch("publication_work").sole
    @connection.update!(allowed_lanes: ["news"])

    post "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/renew.json",
         headers: headers(correlation: "scope-narrowing-renew"),
         params: {
           lease_token: claimed.fetch("lease_token"),
           requested_lease_seconds: 60,
           correlation_id: "scope-narrowing-renew",
         },
         as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error_code")).to eq("scope_denied")

    body = acknowledgement(claimed, record, correlation: "scope-narrowing-ack")
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "scope-narrowing-ack"), params: body, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error_code")).to eq("scope_denied")
  end

  it "rejects unknown nested fields and prevents catalog profile authority expansion" do
    correlation = "catalog-authority-1"
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: correlation),
        params: {
          platform_profile: "ghost",
          base_catalog_revision: "catalog:ghost:1",
          segments: catalog_segments,
          correlation_id: correlation,
        },
        as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error_code")).to eq("policy_denied")

    install_catalog
    _, _, record = create_source
    materialize_source
    claim(correlation: "unknown-claim")
    claimed = response.parsed_body.fetch("publication_work").sole
    ack_correlation = "unknown-ack"
    body = acknowledgement(claimed, record, correlation: ack_correlation)
    body[:destination_binding][:invented_control] = true
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: ack_correlation), params: body, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error_code")).to eq("unknown_field")
  end

  it "derives a new update from an authorized mapped topic without rewriting its source post" do
    install_catalog
    topic, source_post, record = create_source
    materialize_source
    claim(correlation: "lifecycle-initial-claim")
    initial = response.parsed_body.fetch("publication_work").sole
    correlation = "lifecycle-initial-ack"
    put "/discussion-bridge/v1/publication-work/#{initial.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: correlation),
        params: acknowledgement(initial, record, correlation: correlation),
        as: :json
    expect(response).to have_http_status(:ok), response.body

    original_raw = source_post.raw
    original_version = source_post.version
    changed_at = 10.minutes.from_now
    source_post.update_columns(cooked: "<p>Authorized wiki update</p>", updated_at: changed_at)
    DiscussionBridge::SourcePublicationLifecycle.reconcile_topic!(topic.id)

    latest = record.publication_works.order(:id).last
    expect(latest).to have_attributes(action: "update", state: "available")
    expect(latest.source_revision_record.source_updated_at).to be_within(0.000001).of(changed_at)
    expect(source_post.reload).to have_attributes(raw: original_raw, version: original_version)

    unrelated = Fabricate(:topic, user: admin, category: category)
    Fabricate(:post, topic: unrelated, user: admin, post_number: 1)
    expect(DiscussionBridge::SourcePublicationLifecycle.enqueue_topic(unrelated.id)).to eq(false)
  end

  it "keeps discussion status separate while staff exclude and restore one mapped publication" do
    SiteSetting.discussion_bridge_publisher_enabled = true
    install_catalog
    topic, _, record = create_source
    materialize_source
    sign_in(admin)

    put "/discussion-bridge/v1/publisher/topics/#{topic.id}/connections/#{@connection.id}/policy.json",
        params: { publication_policy: { decision: "exclude" } },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("discussion")).to include(
      "visible" => true,
      "closed" => false,
    )
    publication = response.parsed_body.fetch("publications").sole
    expect(publication.fetch("override")).to include("decision" => "exclude")
    expect(publication.fetch("effective")).to include(
      "included" => false,
      "reason" => "operator_hold",
    )
    expect(record.source_revocations.where(restored_at: nil).sole.reason).to eq("operator_hold")
    expect(record.publication_works.order(:id).last.action).to eq("hold")

    put "/discussion-bridge/v1/publisher/topics/#{topic.id}/connections/#{@connection.id}/policy.json",
        params: { publication_policy: { decision: "include" } },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("publications").sole.fetch("override")).to include(
      "decision" => "include",
    )
    expect(record.source_revocations.where(restored_at: nil)).to be_empty
    expect(record.publication_works.order(:id).last.action).to eq("restore")
  end

  it "records a catalog refresh request, previews authoritative mappings, and clears the request on catalog receipt" do
    install_catalog
    _, _, record = create_source
    materialize_source
    sign_in(admin)

    post "/discussion-bridge/admin/content-connections/#{@connection.id}/request-catalog-refresh.json",
         as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("content_connection", "catalog", "refresh_requested_at")).to be_present

    get "/discussion-bridge/admin/content-connections/#{@connection.id}/publication-preview.json"
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("total" => 1, "truncated" => false)
    expect(response.parsed_body.fetch("items").sole).to include(
      "resource_id" => record.resource_id,
      "topic_id" => record.topic_id,
      "decision" => "inherit",
    )

    sign_out
    revision = @connection.platform_catalogs.find_by!(current: true).catalog_revision
    correlation = "catalog-refresh-response-1"
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: correlation),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: revision,
          segments: catalog_segments,
          correlation_id: correlation,
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(@connection.reload.platform_catalog_refresh_requested_at).to be_nil
  end

  it "requires a staff-confirmed correction before retrying operator-attention work" do
    SiteSetting.discussion_bridge_publisher_enabled = true
    install_catalog
    create_source
    materialize_source
    work = DiscussionBridgePublicationWork.order(:id).last
    work.update_columns(
      state: "operator_attention",
      failure_code: "destination_unavailable",
      failure_detail: "Destination remained unavailable.",
    )
    sign_in(admin)

    post "/discussion-bridge/admin/publishing/work/#{work.id}/retry.json",
         params: { retry: { condition_corrected: false } },
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include(
      "condition correction must be confirmed",
    )

    post "/discussion-bridge/admin/publishing/work/#{work.id}/retry.json",
         params: { retry: { condition_corrected: true } },
         as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("publication_work")).to include(
      "state" => "available",
      "retry_generation" => 1,
      "attempt_count" => 1,
    )
  end

  it "keeps To-only capability usable and requires explicit native catalog mapping" do
    sign_in(admin)
    post "/discussion-bridge/admin/content-connections.json", params: {
      content_connection: {
        name: "To-only receiver",
        platform: "wordpress",
        allowed_origins: ["https://publisher.example"],
        allowed_directions: ["to_discourse"],
        allowed_lanes: ["articles"],
      },
    }, as: :json
    expect(response).to have_http_status(:created)
    result = response.parsed_body
    @connection = DiscussionBridgeContentConnection.find(result.dig("content_connection", "id"))
    @secret = result.fetch("secret")
    sign_out
    get "/discussion-bridge/v1/connection.json", headers: headers(correlation: "to-only-capability")
    expect(response).to have_http_status(:ok)

    @connection.destroy!
    sign_in(admin)
    post "/discussion-bridge/admin/content-connections.json", params: {
      content_connection: {
        name: "Catalog receiver",
        platform: "wordpress",
        allowed_origins: ["https://publisher.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["articles"],
      },
    }, as: :json
    result = response.parsed_body
    @connection = DiscussionBridgeContentConnection.find(result.dig("content_connection", "id"))
    @secret = result.fetch("secret")
    initial = @connection.destination_policies.sole.fetch("catalog_revision")
    pending_policy = @connection.destination_policies.deep_dup
    pending_policy_revision = @connection.policy_revision
    expect(pending_policy.sole.dig("container_mapping", "destination")).to eq(
      "discussion-bridge:pending-catalog-mapping",
    )
    sign_out
    segments = catalog_segments
    put "/discussion-bridge/v1/platform-catalog.json", headers: headers(correlation: "catalog-adopt"), params: {
      platform_profile: "wordpress",
      base_catalog_revision: initial,
      segments: segments,
      correlation_id: "catalog-adopt",
    }, as: :json
    expect(response).to have_http_status(:ok)
    catalog_revision = response.parsed_body.fetch("catalog_revision")
    expect(@connection.reload).to have_attributes(
      destination_policies: pending_policy,
      policy_revision: pending_policy_revision,
    )
    pending_topic = Fabricate(:topic, user: admin, category: category, visible: true)
    Fabricate(:post, topic: pending_topic, user: admin, post_number: 1, raw: "Pending publication")
    expect do
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: pending_topic.id,
        external_id: "pending-publication",
        canonical_url: "https://publisher.example/articles/pending-publication/",
        lane: "articles",
      )
    end.to raise_error(ArgumentError, /does not permit From Discourse/)
    expect(@connection.bridge_records).to be_empty
    expect(@connection.publication_works).to be_empty

    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json", params: {
      content_connection: {
        name: "Catalog receiver renamed",
        platform: "wordpress",
        allowed_directions: ["from_discourse"],
        generate_topic_toc: true,
        network_enabled: false,
      },
    }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(@connection.reload).to have_attributes(
      destination_policies: pending_policy,
      policy_revision: pending_policy_revision,
    )

    approved_policy = destination_policy(catalog_revision: catalog_revision)
    unavailable_policy = approved_policy.deep_merge(
      "container_mapping" => { "destination" => "site:not-in-the-catalog" },
    )
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json", params: {
      content_connection: { publication_policy: unavailable_policy },
    }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(@connection.reload.destination_policies).to eq(pending_policy)

    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json", params: {
      content_connection: { publication_policy: approved_policy },
    }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(@connection.reload.destination_policies).to eq([approved_policy])
    expect(@connection.policy_revision).not_to eq(pending_policy_revision)
    approved_policy_revision = @connection.policy_revision
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json", params: {
      content_connection: {
        name: "Catalog receiver final",
        platform: "wordpress",
        allowed_directions: ["from_discourse"],
        network_enabled: false,
      },
    }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(@connection.reload).to have_attributes(
      destination_policies: [approved_policy],
      policy_revision: approved_policy_revision,
    )
    sign_out

    create_source
    materialize_source
    claim(correlation: "catalog-adopt-claim")
    expect(response.parsed_body.fetch("publication_work").length).to eq(1)
  end

  it "accepts descriptive Statamic Flat catalog bootstrap without activating publication" do
    @connection.destroy!
    sign_in(admin)
    post "/discussion-bridge/admin/content-connections.json", params: {
      content_connection: {
        name: "Statamic receiver",
        platform: "statamic",
        allowed_origins: ["https://publisher.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["articles"],
      },
    }, as: :json
    expect(response).to have_http_status(:created), response.body
    @connection = DiscussionBridgeContentConnection.find(response.parsed_body.dig("content_connection", "id"))
    @secret = response.parsed_body.fetch("secret")
    pending = @connection.destination_policies.deep_dup
    sign_out

    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: "statamic-flat-bootstrap"),
        params: {
          platform_profile: "statamic_flat",
          base_catalog_revision: "catalog:statamic_flat:initial",
          segments: catalog_segments,
          correlation_id: "statamic-flat-bootstrap",
        },
        as: :json

    expect(response).to have_http_status(:ok), response.body
    expect(@connection.reload.destination_policies).to eq(pending)
    expect(DiscussionBridge::ConnectionCapability.publication_active?(@connection)).to be(false)
  end

  it "applies an explicit mapping reset when preservation is not requested" do
    revision = install_catalog
    existing = @connection.destination_policies.sole.deep_stringify_keys
    expect(existing.fetch("taxonomy_mapping")).to eq("mode" => "mapped_only")
    reset = existing.deep_dup
    reset["catalog_revision"] = revision
    reset["taxonomy_mapping"] = { "mode" => "source_attribution" }
    reset["author_mapping"] = { "mode" => "source_attribution" }

    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: {
          content_connection: {
            publication_policy: reset,
            replace_existing_policy_fields: true,
          },
        },
        as: :json

    expect(response).to have_http_status(:ok), response.body
    expect(@connection.reload.destination_policies.sole).to include(
      "taxonomy_mapping" => { "mode" => "source_attribution" },
      "author_mapping" => { "mode" => "source_attribution" },
    )

    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: {
          content_connection: {
            publication_policy: reset,
            preserve_existing_policy_fields: true,
            replace_existing_policy_fields: true,
          },
        },
        as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "delivers withdrawal work and lets a policy-only change finish an active lease" do
    install_catalog
    _, _, record = create_source
    _, _, failure_record = create_source(title: "Second publication source")
    materialize_source
    claim(correlation: "policy-claim", maximum_items: 2)
    claims = response.parsed_body.fetch("publication_work")
    expect(claims.length).to eq(2)
    claimed = claims.find { |item| item.fetch("resource_id") == record.resource_id }
    failure_claim = claims.find { |item| item.fetch("resource_id") == failure_record.resource_id }
    @connection.update!(policy_revision: "policy:test:changed")
    post "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/renew.json",
         headers: headers(correlation: "policy-renew"),
         params: { lease_token: claimed.fetch("lease_token"), requested_lease_seconds: 60,
                   correlation_id: "policy-renew" }, as: :json
    expect(response).to have_http_status(:ok)
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "policy-ack"),
        params: acknowledgement(claimed, record, correlation: "policy-ack"), as: :json
    expect(response).to have_http_status(:ok)
    put "/discussion-bridge/v1/publication-work/#{failure_claim.fetch("work_id")}/failure.json",
        headers: headers(correlation: "policy-failure"),
        params: {
          lease_token: failure_claim.fetch("lease_token"),
          error_code: "destination_unavailable",
          error_detail: "Destination temporarily unavailable",
          failed_at: Time.zone.now.iso8601(6),
          correlation_id: "policy-failure",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("resulting_state")).to eq("retry_wait")

    @connection.update!(allowed_lanes: ["news"])
    get "/discussion-bridge/v1/source-revocations.json", headers: headers(correlation: "scope-revoke")
    expect(response).to have_http_status(:ok)
    claim(correlation: "scope-withdrawal")
    withdrawal = response.parsed_body.fetch("publication_work").sole
    expect(withdrawal.fetch("action")).to eq("unpublish")
    withdrawal_record = [record, failure_record].find do |candidate|
      candidate.resource_id == withdrawal.fetch("resource_id")
    end
    post "/discussion-bridge/v1/publication-work/#{withdrawal.fetch("work_id")}/renew.json",
         headers: headers(correlation: "withdrawal-renew"),
         params: {
           lease_token: withdrawal.fetch("lease_token"),
           requested_lease_seconds: 60,
           correlation_id: "withdrawal-renew",
         },
         as: :json
    expect(response).to have_http_status(:ok), response.body
    put "/discussion-bridge/v1/publication-work/#{withdrawal.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "withdrawal-ack"),
        params: acknowledgement(withdrawal, withdrawal_record, correlation: "withdrawal-ack"),
        as: :json
    expect(response).to have_http_status(:ok), response.body

    claim(correlation: "scope-withdrawal-failure")
    failed_withdrawal = response.parsed_body.fetch("publication_work").sole
    failed_withdrawal_record = [record, failure_record].find do |candidate|
      candidate.resource_id == failed_withdrawal.fetch("resource_id")
    end
    put "/discussion-bridge/v1/publication-work/#{failed_withdrawal.fetch("work_id")}/failure.json",
        headers: headers(correlation: "withdrawal-failure"),
        params: {
          lease_token: failed_withdrawal.fetch("lease_token"),
          error_code: "destination_unavailable",
          error_detail: "Withdrawal destination temporarily unavailable",
          failed_at: Time.zone.now.iso8601(6),
          correlation_id: "withdrawal-failure",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("resulting_state")).to eq("retry_wait")

    travel_to(61.seconds.from_now) do
      claim(correlation: "scope-withdrawal-retry")
      retried = response.parsed_body.fetch("publication_work").sole
      expect(retried).to include(
        "work_id" => failed_withdrawal.fetch("work_id"),
        "action" => "unpublish",
        "attempt_count" => 2,
      )
      put "/discussion-bridge/v1/publication-work/#{retried.fetch("work_id")}/acknowledgement.json",
          headers: headers(correlation: "withdrawal-retry-ack"),
          params: acknowledgement(
            retried,
            failed_withdrawal_record,
            correlation: "withdrawal-retry-ack",
          ),
          as: :json
      expect(response).to have_http_status(:ok), response.body
    end

    claim(correlation: "scope-withdrawal-complete", maximum_items: 32)
    expect(response.parsed_body.fetch("publication_work")).to be_empty
    expect(@connection.publication_works.where(action: %w[publish update], state: "available")).to be_empty
  end

  it "fails malformed acknowledgements and generated-shape secrets closed" do
    install_catalog
    _, _, record = create_source
    materialize_source
    claim(correlation: "validation-claim")
    claimed = response.parsed_body.fetch("publication_work").sole

    body = acknowledgement(claimed, record, correlation: "validation-ack")
    body.delete(:deployment_state)
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "validation-ack"), params: body, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error_code")).to eq("validation_failed")

    body = acknowledgement(claimed, record, correlation: "validation-ack-2")
    body.delete(:destination_binding)
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "validation-ack-2"), params: body, as: :json
    expect(response).to have_http_status(:unprocessable_entity)

    synthetic = ("-" * 4) + ("Z" * 38) + "A"
    @connection.update!(secret_digest: Digest::SHA256.hexdigest(synthetic))
    @secret = synthetic
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/failure.json",
        headers: headers(correlation: "secret-failure"), params: {
          lease_token: claimed.fetch("lease_token"), error_code: "destination_unavailable",
          error_detail: "Diagnostic #{synthetic}", failed_at: Time.zone.now.iso8601(6),
          correlation_id: "secret-failure",
        }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiscussionBridgePublicationWork.find_by!(work_id: claimed.fetch("work_id")).failure_detail).to be_nil
  end

  it "moves work for a removed catalog destination to operator attention" do
    revision = install_catalog
    create_source
    materialize_source
    work = @connection.publication_works.sole
    segments = catalog_segments
    segments.find { |segment| segment["segment_type"] == "containers" }["items"] = []
    put "/discussion-bridge/v1/platform-catalog.json", headers: headers(correlation: "catalog-remove"), params: {
      platform_profile: "wordpress", base_catalog_revision: revision, segments: segments,
      correlation_id: "catalog-remove",
    }, as: :json
    expect(response).to have_http_status(:ok)
    expect(work.reload).to have_attributes(state: "operator_attention", resolution_error: "operator_action_required")
    claim(correlation: "catalog-remove-claim")
    expect(response.parsed_body.fetch("publication_work")).to be_empty
  end

  it "keeps work unclaimable when its resolved author or term is unavailable" do
    segments = catalog_segments(
      authors: [{ "id" => "author:missing", "name" => "Missing author", "available" => false }],
    )
    segments.find { |segment| segment["segment_type"] == "terms" }["items"] = [
      {
        "id" => "term:missing",
        "taxonomy_id" => "site:categories",
        "name" => "Missing term",
        "parent_id" => nil,
        "available" => false,
      },
    ]
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: "unavailable-mapping-catalog"),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: destination_policy.fetch("catalog_revision"),
          segments: segments,
          correlation_id: "unavailable-mapping-catalog",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    revision = response.parsed_body.fetch("catalog_revision")
    mapped_policy = destination_policy(catalog_revision: revision).deep_merge(
      "taxonomy_mapping" => {
        "mode" => "mapped_only",
        "items" => [
          {
            "source" => "discourse:category:#{category.id}",
            "destination" => "term:missing",
          },
        ],
      },
      "author_mapping" => {
        "mode" => "mapped_only",
        "items" => [
          {
            "source" => "discourse:user:#{admin.id}",
            "destination" => "author:missing",
          },
        ],
      },
    )
    @connection.update!(destination_policies: [mapped_policy])

    create_source
    materialize_source

    expect(@connection.publication_works.sole).to have_attributes(
      state: "operator_attention",
      resolution_error: "operator_action_required",
      resolved_taxonomy: [
        {
          "source_id" => "discourse:category:#{category.id}",
          "destination_id" => "term:missing",
        },
      ],
      resolved_author: {
        "mode" => "mapped_only",
        "destination_id" => "author:missing",
      },
    )
    claim(correlation: "unavailable-mapping-claim")
    expect(response.parsed_body.fetch("publication_work")).to be_empty
  end

  it "holds removed mapped authors and terms without touching another profile's work" do
    segments = catalog_segments
    segments.find { |segment| segment["segment_type"] == "terms" }["items"] = [
      {
        "id" => "term:community",
        "taxonomy_id" => "site:categories",
        "name" => "Community",
        "parent_id" => nil,
        "available" => true,
      },
    ]
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: "mapped-catalog-install"),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: destination_policy.fetch("catalog_revision"),
          segments: segments,
          correlation_id: "mapped-catalog-install",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    revision = response.parsed_body.fetch("catalog_revision")
    mapped_policy = destination_policy(catalog_revision: revision).deep_merge(
      "taxonomy_mapping" => {
        "mode" => "mapped_only",
        "items" => [
          {
            "source" => "discourse:category:#{category.id}",
            "destination" => "term:community",
          },
        ],
      },
      "author_mapping" => {
        "mode" => "mapped_only",
        "items" => [
          {
            "source" => "discourse:user:#{admin.id}",
            "destination" => "author:editor",
          },
        ],
      },
    )
    @connection.update!(destination_policies: [mapped_policy])
    create_source
    materialize_source
    work = @connection.publication_works.sole
    expect(work).to have_attributes(
      resolved_taxonomy: [
        {
          "source_id" => "discourse:category:#{category.id}",
          "destination_id" => "term:community",
        },
      ],
      resolved_author: {
        "mode" => "mapped_only",
        "destination_id" => "author:editor",
      },
    )
    decoy = @connection.publication_works.create!(
      bridge_record: work.bridge_record,
      content_binding: work.content_binding,
      source_revision_record: work.source_revision_record,
      action: "update",
      state: "available",
      source_revision: "decoy:other-profile:1",
      source_revision_sequence: work.source_revision_sequence + 100,
      policy_revision: work.policy_revision,
      destination_policy_id: "destination:other-profile:1",
      catalog_revision: "catalog:other-profile:1",
      presentation_mode: work.presentation_mode,
      resolved_container: work.resolved_container,
      resolved_taxonomy: work.resolved_taxonomy,
      resolved_author: work.resolved_author,
      native_limit_policy: work.native_limit_policy,
      attempt_count: 1,
      retry_generation: 0,
      available_at: Time.zone.now,
    )
    retry_work = work.dup
    retry_work.assign_attributes(
      work_id: nil,
      source_revision: "retry:mapped-profile:1",
      source_revision_sequence: work.source_revision_sequence + 1,
      state: "retry_wait",
      available_at: nil,
      next_retry_at: 1.hour.from_now,
    )
    retry_work.save!
    leased_work = work.dup
    leased_work.assign_attributes(
      work_id: nil,
      source_revision: "leased:mapped-profile:1",
      source_revision_sequence: work.source_revision_sequence + 2,
      state: "leased",
      available_at: nil,
      worker_id: "catalog-review-worker",
      lease_token_digest: Digest::SHA256.hexdigest("catalog-review-lease"),
      stage_token_digest: Digest::SHA256.hexdigest("catalog-review-stage"),
      total_lease_seconds: 300,
      leased_at: Time.zone.now,
      lease_expires_at: 5.minutes.from_now,
    )
    leased_work.save!

    without_author = segments.deep_dup
    without_author.find { |segment| segment["segment_type"] == "authors" }["items"] = []
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: "mapped-author-remove"),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: revision,
          segments: without_author,
          correlation_id: "mapped-author-remove",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    next_revision = response.parsed_body.fetch("catalog_revision")
    expect(work.reload).to have_attributes(
      state: "operator_attention",
      resolution_error: "operator_action_required",
    )
    expect(retry_work.reload).to have_attributes(
      state: "operator_attention",
      resolution_error: "operator_action_required",
    )
    expect(leased_work.reload.state).to eq("leased")
    expect(decoy.reload.state).to eq("available")

    work.update!(state: "available", resolution_error: nil, available_at: Time.zone.now)
    retry_work.update!(
      state: "retry_wait",
      resolution_error: nil,
      next_retry_at: 1.hour.from_now,
    )
    without_term = segments.deep_dup
    without_term.find { |segment| segment["segment_type"] == "terms" }["items"] = []
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: "mapped-term-remove"),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: next_revision,
          segments: without_term,
          correlation_id: "mapped-term-remove",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(work.reload).to have_attributes(
      state: "operator_attention",
      resolution_error: "operator_action_required",
    )
    expect(retry_work.reload).to have_attributes(
      state: "operator_attention",
      resolution_error: "operator_action_required",
    )
    expect(leased_work.reload.state).to eq("leased")
    expect(decoy.reload.state).to eq("available")
  end
end
