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

  def install_catalog
    correlation = "catalog-install-1"
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: correlation),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: destination_policy.fetch("catalog_revision"),
          segments: catalog_segments,
          correlation_id: correlation,
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    revision = response.parsed_body.fetch("catalog_revision")
    @connection.update!(destination_policies: [destination_policy(catalog_revision: revision)])
    revision
  end

  def create_source(content: "<p>Publication body</p>")
    topic = Fabricate(:topic, user: admin, category: category, title: "Publication source", visible: true)
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
    _, _, record = create_source
    materialize_source
    claim(correlation: "static-claim")
    claimed = response.parsed_body.fetch("publication_work").sole
    synchronized_at = Time.zone.now.iso8601(6)

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
  end

  it "resumes retryable static work from its last acknowledged stage" do
    install_catalog
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
end
