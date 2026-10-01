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

  def catalog_segments(authors: [{ "id" => "author:editor", "name" => "Editor", "available" => true }],
                       containers: nil)
    containers ||= [
      { "id" => "site:articles", "name" => "Articles", "kind" => "post_type", "available" => true },
    ]
    [
      {
        "segment_type" => "containers",
        "items" => containers,
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

  def install_catalog(authors: [{ "id" => "author:editor", "name" => "Editor", "available" => true }],
                      containers: nil)
    correlation = "catalog-install-1"
    put "/discussion-bridge/v1/platform-catalog.json",
        headers: headers(correlation: correlation),
        params: {
          platform_profile: "wordpress",
          base_catalog_revision: destination_policy.fetch("catalog_revision"),
          segments: catalog_segments(authors: authors, containers: containers),
          correlation_id: correlation,
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    revision = response.parsed_body.fetch("catalog_revision")
    @connection.update!(destination_policies: [destination_policy(catalog_revision: revision)])
    revision
  end

  def make_destination_static!
    source_connection = @connection
    source_catalog = source_connection.platform_catalogs.where(current: true).sole
    policy = source_connection.destination_policies.sole.deep_stringify_keys
    policy["profile"] = "astro"
    policy["destination_policy_id"] = "destination:astro:articles:1"
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Alpha.21 work Astro",
      platform: "astro",
      allowed_origins: source_connection.allowed_origins,
      allowed_directions: source_connection.allowed_directions,
      allowed_lanes: source_connection.allowed_lanes,
      destination_policies: [policy],
      catalog_required: true,
      policy_revision: source_connection.policy_revision,
    )
    catalog = @connection.platform_catalogs.create!(
      platform_profile: "astro",
      catalog_revision: source_catalog.catalog_revision,
      current: true,
    )
    source_catalog.segments.find_each do |segment|
      catalog.segments.create!(
        segment_type: segment.segment_type,
        items: segment.items.deep_dup,
      )
    end
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
                      synchronized_at: Time.zone.now.iso8601(6),
                      publication_revision: "wordpress:post:revision:1", **extra)
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
        publication_revision: publication_revision,
        content_disposition: "complete",
      },
      synchronized_at: synchronized_at,
      deployment_state: deployment_state,
      verification_state: verification_state,
      correlation_id: correlation,
    }.merge(extra)
  end

  def complete_static_work(claimed, record, prefix:, publication_revision:)
    synchronized_at = Time.zone.now.iso8601(6)
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "#{prefix}-synchronized"),
        params: acknowledgement(
          claimed,
          record,
          correlation: "#{prefix}-synchronized",
          deployment_state: "pending",
          verification_state: "pending",
          synchronized_at: synchronized_at,
          publication_revision: publication_revision,
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body
    deployed_token = response.parsed_body.fetch("next_stage_token")

    deployed_at = 1.second.from_now.iso8601(6)
    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "#{prefix}-deployed"),
        params: acknowledgement(
          claimed,
          record,
          correlation: "#{prefix}-deployed",
          stage: "deployed",
          stage_token: deployed_token,
          deployment_state: "deployed",
          verification_state: "pending",
          synchronized_at: synchronized_at,
          deployed_at: deployed_at,
          publication_revision: publication_revision,
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body
    verified_token = response.parsed_body.fetch("next_stage_token")

    put "/discussion-bridge/v1/publication-work/#{claimed.fetch("work_id")}/acknowledgement.json",
        headers: headers(correlation: "#{prefix}-verified"),
        params: acknowledgement(
          claimed,
          record,
          correlation: "#{prefix}-verified",
          stage: "verified",
          stage_token: verified_token,
          deployment_state: "deployed",
          verification_state: "verified",
          synchronized_at: synchronized_at,
          deployed_at: deployed_at,
          publicly_verified_at: 2.seconds.from_now.iso8601(6),
          publication_revision: publication_revision,
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body
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

  it "rejects a platform change without disturbing publication authority or queued work" do
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
    original = @connection.attributes.slice(
      "name",
      "platform",
      "public_id",
      "secret_digest",
      "destination_policies",
      "policy_revision",
    )

    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: {
          content_connection: {
            name: "Rejected Ghost replacement",
            platform: "ghost",
            allowed_directions: ["from_discourse"],
          },
        },
        as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include(
      "connection platform cannot be changed after creation",
    )
    sign_out

    expect(@connection.reload.attributes.slice(*original.keys)).to eq(original)
    expect(DiscussionBridge::ConnectionCapability.publication_active?(@connection)).to be(true)
    expect(@connection.publication_works.where(action: "unpublish")).to be_empty
    expect(queued.reload).to have_attributes(
      action: "update",
      state: "available",
      resolved_container: { "id" => "site:queued-only", "kind" => "post_type" },
    )

    claim(correlation: "platform-change-rejected-claim")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("publication_work").sole).to include(
      "work_id" => queued.work_id,
      "action" => "update",
      "destination_policy_id" => published.fetch("destination_policy_id"),
    )
  end

  it "keeps one removed policy withdrawable while an unchanged policy continues" do
    containers = [
      { "id" => "site:articles", "name" => "Articles", "kind" => "post_type", "available" => true },
      { "id" => "site:archive", "name" => "Archive", "kind" => "post_type", "available" => true },
    ]
    install_catalog(containers: containers)
    policy_a = @connection.destination_policies.sole.deep_stringify_keys
    policy_b = policy_a.deep_dup
    policy_b["destination_policy_id"] = "destination:wordpress:archive:2"
    policy_b["container_mapping"]["destination"] = "site:archive"
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
    expect(published.to_h { |item| [item.fetch("destination_policy_id"), item.dig("resolved_container", "id")] }).to eq(
      policy_a.fetch("destination_policy_id") => "site:articles",
      policy_b.fetch("destination_policy_id") => "site:archive",
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

    restoration = @connection.publication_works.where(
      destination_policy_id: policy_b.fetch("destination_policy_id"),
      action: %w[create update],
    ).where.not(state: "acknowledged").sole
    expect(restoration.resolved_container.fetch("id")).to eq("site:archive")

    claim(correlation: "multi-policy-withdrawal", lease_seconds: 1)
    first_withdrawal_claim = response.parsed_body.fetch("publication_work").sole
    expect(first_withdrawal_claim).to include(
      "work_id" => withdrawal.work_id,
      "action" => "unpublish",
      "destination_policy_id" => policy_a.fetch("destination_policy_id"),
      "resolved_container" => include("id" => "site:articles"),
    )
    claim(correlation: "multi-policy-blocked-by-active-withdrawal")
    expect(response.parsed_body.fetch("publication_work")).to be_empty

    retry_at = nil
    travel_to(2.seconds.from_now) do
      claim(correlation: "multi-policy-expired-withdrawal")
      expired_withdrawal_claim = response.parsed_body.fetch("publication_work").sole
      expect(expired_withdrawal_claim).to include(
        "work_id" => withdrawal.work_id,
        "action" => "unpublish",
        "destination_policy_id" => policy_a.fetch("destination_policy_id"),
      )
      expect(expired_withdrawal_claim.fetch("lease_token")).not_to eq(
        first_withdrawal_claim.fetch("lease_token"),
      )
      claim(correlation: "multi-policy-blocked-by-reclaimed-withdrawal")
      expect(response.parsed_body.fetch("publication_work")).to be_empty

      put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/failure.json",
          headers: headers(correlation: "multi-policy-withdrawal-failure"),
          params: {
            lease_token: expired_withdrawal_claim.fetch("lease_token"),
            error_code: "destination_unavailable",
            error_detail: "Articles withdrawal is temporarily unavailable.",
            failed_at: Time.zone.now.iso8601(6),
            correlation_id: "multi-policy-withdrawal-failure",
          },
          as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(withdrawal.reload.state).to eq("retry_wait")

      claim(correlation: "multi-policy-restoration")
      restoration_claim = response.parsed_body.fetch("publication_work").sole
      expect(restoration_claim).to include(
        "work_id" => restoration.work_id,
        "destination_policy_id" => policy_b.fetch("destination_policy_id"),
        "resolved_container" => include("id" => "site:archive"),
      )
      put "/discussion-bridge/v1/publication-work/#{restoration.work_id}/acknowledgement.json",
          headers: headers(correlation: "multi-policy-restored"),
          params: acknowledgement(
            restoration_claim,
            record,
            correlation: "multi-policy-restored",
            publication_revision: "wordpress:archive:revision:2",
          ),
          as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(restoration.reload.state).to eq("acknowledged")
      retry_at = withdrawal.next_retry_at
    end

    withdrawal_acknowledgement = nil
    travel_to(retry_at + 1.second) do
      claim(correlation: "multi-policy-withdrawal-retry")
      retried_withdrawal = response.parsed_body.fetch("publication_work").sole
      expect(retried_withdrawal).to include(
        "work_id" => withdrawal.work_id,
        "attempt_count" => 2,
        "destination_policy_id" => policy_a.fetch("destination_policy_id"),
        "resolved_container" => include("id" => "site:articles"),
      )
      withdrawal_acknowledgement = acknowledgement(
        retried_withdrawal,
        record,
        correlation: "multi-policy-withdrawn",
        publication_revision: "wordpress:articles:withdrawn:2",
      )
      put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/acknowledgement.json",
          headers: headers(correlation: "multi-policy-withdrawn"),
          params: withdrawal_acknowledgement,
          as: :json
      expect(response).to have_http_status(:ok), response.body
    end

    expect(withdrawal.reload.state).to eq("acknowledged")
    expect(restoration.reload.state).to eq("acknowledged")
    put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/acknowledgement.json",
        headers: headers(correlation: "multi-policy-withdrawn"),
        params: withdrawal_acknowledgement,
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("resulting_state" => "acknowledged", "terminal" => true)
    DiscussionBridge::SourceRevocationRegistry.reconcile_record!(
      record: record,
      connection: @connection.reload,
    )
    expect(@connection.publication_works.where(action: "unpublish").count).to eq(1)
  end

  it "retains a static withdrawal revision while another policy completes" do
    containers = [
      { "id" => "site:articles", "name" => "Articles", "kind" => "post_type", "available" => true },
      { "id" => "site:archive", "name" => "Archive", "kind" => "post_type", "available" => true },
    ]
    install_catalog(containers: containers)
    make_destination_static!
    policy_a = @connection.destination_policies.sole.deep_stringify_keys
    policy_b = policy_a.deep_dup
    policy_b["destination_policy_id"] = "destination:astro:archive:2"
    policy_b["container_mapping"]["destination"] = "site:archive"
    @connection.update!(
      destination_policies: [policy_a, policy_b],
      policy_revision: "policy:static-two-destinations:1",
    )
    _, _, record = create_source
    materialize_source

    2.times do |index|
      claim(correlation: "static-multi-publish-#{index}")
      item = response.parsed_body.fetch("publication_work").sole
      complete_static_work(
        item,
        record,
        prefix: "static-multi-publish-#{index}",
        publication_revision: "astro:initial:revision:#{index}",
      )
    end

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
    restoration = @connection.publication_works.where(
      destination_policy_id: policy_b.fetch("destination_policy_id"),
      action: %w[create update],
    ).where.not(state: "acknowledged").sole
    expect(withdrawal.resolved_container.fetch("id")).to eq("site:articles")
    expect(restoration.resolved_container.fetch("id")).to eq("site:archive")

    claim(correlation: "static-withdrawal-initial")
    withdrawal_claim = response.parsed_body.fetch("publication_work").sole
    synchronized_at = Time.zone.now.iso8601(6)
    publication_revision_a = "astro:articles:withdrawal:PA"
    put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/acknowledgement.json",
        headers: headers(correlation: "static-withdrawal-synchronized"),
        params: acknowledgement(
          withdrawal_claim,
          record,
          correlation: "static-withdrawal-synchronized",
          deployment_state: "pending",
          verification_state: "pending",
          synchronized_at: synchronized_at,
          publication_revision: publication_revision_a,
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(withdrawal.reload).to have_attributes(
      state: "awaiting_deployment",
      last_acknowledged_stage: "synchronized",
    )

    put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/failure.json",
        headers: headers(correlation: "static-withdrawal-deploy-failure"),
        params: {
          lease_token: withdrawal_claim.fetch("lease_token"),
          error_code: "deploy_failed",
          error_detail: "Articles cleanup deployment is temporarily unavailable.",
          failed_at: Time.zone.now.iso8601(6),
          correlation_id: "static-withdrawal-deploy-failure",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(withdrawal.reload.state).to eq("retry_wait")

    publication_revision_b = "astro:archive:restoration:PB"
    claim(correlation: "static-restoration-claim")
    restoration_claim = response.parsed_body.fetch("publication_work").sole
    expect(restoration_claim.fetch("work_id")).to eq(restoration.work_id)
    complete_static_work(
      restoration_claim,
      record,
      prefix: "static-restoration",
      publication_revision: publication_revision_b,
    )
    binding = record.active_binding("presentation").reload
    expect(binding).to have_attributes(
      publication_revision: publication_revision_b,
      deployment_state: "deployed",
      verification_state: "verified",
    )

    first_retry_at = withdrawal.reload.next_retry_at
    second_retry_at = nil
    deployed_at = nil
    travel_to(first_retry_at + 1.second) do
      claim(correlation: "static-withdrawal-deploy-retry")
      deploy_claim = response.parsed_body.fetch("publication_work").sole
      expect(deploy_claim).to include(
        "work_id" => withdrawal.work_id,
        "attempt_count" => 2,
      )
      deployed_at = Time.zone.now.iso8601(6)
      put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/acknowledgement.json",
          headers: headers(correlation: "static-withdrawal-deployed"),
          params: acknowledgement(
            deploy_claim,
            record,
            correlation: "static-withdrawal-deployed",
            stage: "deployed",
            deployment_state: "deployed",
            verification_state: "pending",
            synchronized_at: synchronized_at,
            deployed_at: deployed_at,
            publication_revision: publication_revision_a,
          ),
          as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(binding.reload).to have_attributes(
        publication_revision: publication_revision_b,
        deployment_state: "deployed",
        verification_state: "verified",
      )

      put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/failure.json",
          headers: headers(correlation: "static-withdrawal-verification-failure"),
          params: {
            lease_token: deploy_claim.fetch("lease_token"),
            error_code: "public_verification_failed",
            error_detail: "Articles cleanup verification is temporarily unavailable.",
            failed_at: Time.zone.now.iso8601(6),
            correlation_id: "static-withdrawal-verification-failure",
          },
          as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(binding.reload).to have_attributes(
        publication_revision: publication_revision_b,
        deployment_state: "deployed",
        verification_state: "verified",
      )
      second_retry_at = withdrawal.reload.next_retry_at
    end

    travel_to(second_retry_at + 1.second) do
      claim(correlation: "static-withdrawal-verification-retry")
      verification_claim = response.parsed_body.fetch("publication_work").sole
      expect(verification_claim).to include(
        "work_id" => withdrawal.work_id,
        "attempt_count" => 3,
      )
      put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/acknowledgement.json",
          headers: headers(correlation: "static-withdrawal-verified"),
          params: acknowledgement(
            verification_claim,
            record,
            correlation: "static-withdrawal-verified",
            stage: "verified",
            deployment_state: "deployed",
            verification_state: "verified",
            synchronized_at: synchronized_at,
            deployed_at: deployed_at,
            publicly_verified_at: Time.zone.now.iso8601(6),
            publication_revision: publication_revision_a,
          ),
          as: :json
      expect(response).to have_http_status(:ok), response.body
    end

    expect(withdrawal.reload).to have_attributes(
      state: "acknowledged",
      last_acknowledged_stage: "verified",
    )
    expect(binding.reload).to have_attributes(
      publication_revision: publication_revision_b,
      deployment_state: "deployed",
      verification_state: "verified",
    )
  end

  it "preserves removed-policy cleanup through another policy and authorized manual retry" do
    SiteSetting.discussion_bridge_publisher_enabled = true
    containers = [
      { "id" => "site:articles", "name" => "Articles", "kind" => "post_type", "available" => true },
      { "id" => "site:archive", "name" => "Archive", "kind" => "post_type", "available" => true },
    ]
    install_catalog(containers: containers)
    policy_a = @connection.destination_policies.sole.deep_stringify_keys
    policy_b = policy_a.deep_dup
    policy_b["destination_policy_id"] = "destination:wordpress:archive:2"
    policy_b["container_mapping"]["destination"] = "site:archive"
    @connection.update!(
      destination_policies: [policy_a, policy_b],
      policy_revision: "policy:operator-attention-destinations:1",
    )
    _, _, record = create_source
    materialize_source
    2.times do |index|
      claim(correlation: "operator-multi-publish-#{index}")
      item = response.parsed_body.fetch("publication_work").sole
      put "/discussion-bridge/v1/publication-work/#{item.fetch("work_id")}/acknowledgement.json",
          headers: headers(correlation: "operator-multi-published-#{index}"),
          params: acknowledgement(
            item,
            record,
            correlation: "operator-multi-published-#{index}",
            publication_revision: "wordpress:operator:initial:#{index}",
          ),
          as: :json
      expect(response).to have_http_status(:ok), response.body
    end

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
    restoration = @connection.publication_works.where(
      destination_policy_id: policy_b.fetch("destination_policy_id"),
      action: %w[create update],
    ).where.not(state: "acknowledged").sole
    1.upto(4) do |attempt|
      claim(correlation: "operator-withdrawal-attempt-#{attempt}")
      failed_claim = response.parsed_body.fetch("publication_work").sole
      expect(failed_claim).to include(
        "work_id" => withdrawal.work_id,
        "attempt_count" => attempt,
        "resolved_container" => include("id" => "site:articles"),
      )
      correlation = "operator-withdrawal-failure-#{attempt}"
      put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/failure.json",
          headers: headers(correlation: correlation),
          params: {
            lease_token: failed_claim.fetch("lease_token"),
            error_code: "destination_unavailable",
            error_detail: "Articles cleanup remained unavailable.",
            failed_at: Time.zone.now.iso8601(6),
            correlation_id: correlation,
          },
          as: :json
      expect(response).to have_http_status(:ok), response.body
      withdrawal.reload
      if attempt < 4
        expect(withdrawal.state).to eq("retry_wait")
        travel_to(withdrawal.next_retry_at + 1.second)
      else
        expect(withdrawal.state).to eq("operator_attention")
      end
    end

    claim(correlation: "operator-surviving-policy")
    restoration_claim = response.parsed_body.fetch("publication_work").sole
    expect(restoration_claim.fetch("work_id")).to eq(restoration.work_id)
    put "/discussion-bridge/v1/publication-work/#{restoration.work_id}/acknowledgement.json",
        headers: headers(correlation: "operator-surviving-policy-complete"),
        params: acknowledgement(
          restoration_claim,
          record,
          correlation: "operator-surviving-policy-complete",
          publication_revision: "wordpress:archive:operator:PB",
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(withdrawal.reload.state).to eq("operator_attention")

    sign_in(admin)
    post "/discussion-bridge/admin/publishing/work/#{withdrawal.id}/retry.json",
         params: { retry: { condition_corrected: false } },
         as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(withdrawal.reload.state).to eq("operator_attention")

    post "/discussion-bridge/admin/publishing/work/#{withdrawal.id}/retry.json",
         params: { retry: { condition_corrected: true } },
         as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(withdrawal.reload).to have_attributes(
      state: "available",
      retry_generation: 1,
      attempt_count: 1,
    )
    sign_out

    claim(correlation: "operator-withdrawal-retry")
    retried_withdrawal = response.parsed_body.fetch("publication_work").sole
    expect(retried_withdrawal).to include(
      "work_id" => withdrawal.work_id,
      "retry_generation" => 1,
      "destination_policy_id" => policy_a.fetch("destination_policy_id"),
      "resolved_container" => include("id" => "site:articles"),
    )
    put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/acknowledgement.json",
        headers: headers(correlation: "operator-withdrawal-complete"),
        params: acknowledgement(
          retried_withdrawal,
          record,
          correlation: "operator-withdrawal-complete",
          publication_revision: "wordpress:articles:operator:PA",
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(withdrawal.reload.state).to eq("acknowledged")
    expect(restoration.reload.state).to eq("acknowledged")
  end

  it "does not infer static binding ownership from an equal revision token" do
    containers = [
      { "id" => "site:articles", "name" => "Articles", "kind" => "post_type", "available" => true },
      { "id" => "site:archive", "name" => "Archive", "kind" => "post_type", "available" => true },
    ]
    install_catalog(containers: containers)
    make_destination_static!
    policy_a = @connection.destination_policies.sole.deep_stringify_keys
    policy_b = policy_a.deep_dup
    policy_b["destination_policy_id"] = "destination:astro:archive:equal-revision"
    policy_b["container_mapping"]["destination"] = "site:archive"
    @connection.update!(
      destination_policies: [policy_a, policy_b],
      policy_revision: "policy:static-equal-revision",
    )
    _, _, record = create_source
    materialize_source

    claim(correlation: "equal-revision-a-claim")
    claim_a = response.parsed_body.fetch("publication_work").sole
    work_a = DiscussionBridgePublicationWork.find_by!(work_id: claim_a.fetch("work_id"))
    expect(claim_a.dig("resolved_container", "id")).to eq("site:articles")
    shared_revision = "astro:opaque:shared-revision"
    synchronized_at = Time.zone.now.iso8601(6)
    put "/discussion-bridge/v1/publication-work/#{work_a.work_id}/acknowledgement.json",
        headers: headers(correlation: "equal-revision-a-synchronized"),
        params: acknowledgement(
          claim_a,
          record,
          correlation: "equal-revision-a-synchronized",
          deployment_state: "pending",
          verification_state: "pending",
          synchronized_at: synchronized_at,
          publication_revision: shared_revision,
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body
    put "/discussion-bridge/v1/publication-work/#{work_a.work_id}/failure.json",
        headers: headers(correlation: "equal-revision-a-failure"),
        params: {
          lease_token: claim_a.fetch("lease_token"),
          error_code: "deploy_failed",
          error_detail: "Articles deployment is waiting while archive continues.",
          failed_at: Time.zone.now.iso8601(6),
          correlation_id: "equal-revision-a-failure",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body

    claim(correlation: "equal-revision-b-claim")
    claim_b = response.parsed_body.fetch("publication_work").sole
    expect(claim_b.dig("resolved_container", "id")).to eq("site:archive")
    complete_static_work(
      claim_b,
      record,
      prefix: "equal-revision-b",
      publication_revision: shared_revision,
    )
    binding = record.active_binding("presentation").reload
    b_projection = binding.attributes.slice(
      "publication_revision",
      "deployment_state",
      "verification_state",
      "deployed_at_wire",
      "publicly_verified_at_wire",
    )
    expect(b_projection).to include(
      "publication_revision" => shared_revision,
      "deployment_state" => "deployed",
      "verification_state" => "verified",
    )

    deployed_at = nil
    verification_retry_at = nil
    travel_to(work_a.reload.next_retry_at + 1.second) do
      claim(correlation: "equal-revision-a-retry")
      retry_a = response.parsed_body.fetch("publication_work").sole
      expect(retry_a.fetch("work_id")).to eq(work_a.work_id)
      deployed_at = Time.zone.now.iso8601(6)
      put "/discussion-bridge/v1/publication-work/#{work_a.work_id}/acknowledgement.json",
          headers: headers(correlation: "equal-revision-a-deployed"),
          params: acknowledgement(
            retry_a,
            record,
            correlation: "equal-revision-a-deployed",
            stage: "deployed",
            deployment_state: "deployed",
            verification_state: "pending",
            synchronized_at: synchronized_at,
            deployed_at: deployed_at,
            publication_revision: shared_revision,
          ),
          as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(binding.reload.attributes.slice(*b_projection.keys)).to eq(b_projection)

      put "/discussion-bridge/v1/publication-work/#{work_a.work_id}/failure.json",
          headers: headers(correlation: "equal-revision-a-verification-failure"),
          params: {
            lease_token: retry_a.fetch("lease_token"),
            error_code: "public_verification_failed",
            error_detail: "Articles verification remains unavailable.",
            failed_at: Time.zone.now.iso8601(6),
            correlation_id: "equal-revision-a-verification-failure",
          },
          as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(binding.reload.attributes.slice(*b_projection.keys)).to eq(b_projection)
      verification_retry_at = work_a.reload.next_retry_at
    end

    travel_to(verification_retry_at + 1.second) do
      claim(correlation: "equal-revision-a-verification-retry")
      verification_a = response.parsed_body.fetch("publication_work").sole
      expect(verification_a.fetch("work_id")).to eq(work_a.work_id)
      put "/discussion-bridge/v1/publication-work/#{work_a.work_id}/acknowledgement.json",
          headers: headers(correlation: "equal-revision-a-verified"),
          params: acknowledgement(
            verification_a,
            record,
            correlation: "equal-revision-a-verified",
            stage: "verified",
            deployment_state: "deployed",
            verification_state: "verified",
            synchronized_at: synchronized_at,
            deployed_at: deployed_at,
            publicly_verified_at: Time.zone.now.iso8601(6),
            publication_revision: shared_revision,
          ),
          as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(work_a.reload.state).to eq("acknowledged")
      expect(binding.reload.attributes.slice(*b_projection.keys)).to eq(b_projection)
    end
  end

  it "supersedes stale cleanup only after the same destination is restored and issued" do
    containers = [
      { "id" => "site:articles", "name" => "Articles", "kind" => "post_type", "available" => true },
      { "id" => "site:archive", "name" => "Archive", "kind" => "post_type", "available" => true },
      { "id" => "site:news", "name" => "News", "kind" => "post_type", "available" => true },
    ]
    install_catalog(containers: containers)
    policy_a = @connection.destination_policies.sole.deep_stringify_keys
    policy_b = policy_a.deep_dup
    policy_b["destination_policy_id"] = "destination:wordpress:archive:2"
    policy_b["container_mapping"]["destination"] = "site:archive"
    @connection.update!(
      destination_policies: [policy_a, policy_b],
      policy_revision: "policy:same-target:initial",
    )
    _, _, record = create_source
    materialize_source
    2.times do |index|
      claim(correlation: "same-target-publish-#{index}")
      item = response.parsed_body.fetch("publication_work").sole
      put "/discussion-bridge/v1/publication-work/#{item.fetch("work_id")}/acknowledgement.json",
          headers: headers(correlation: "same-target-published-#{index}"),
          params: acknowledgement(
            item,
            record,
            correlation: "same-target-published-#{index}",
            publication_revision: "wordpress:same-target:initial:#{index}",
          ),
          as: :json
      expect(response).to have_http_status(:ok), response.body
    end

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
    surviving_restoration = @connection.publication_works.where(
      destination_policy_id: policy_b.fetch("destination_policy_id"),
      action: %w[create update],
    ).where.not(state: "acknowledged").sole

    claim(correlation: "same-target-withdrawal")
    withdrawal_claim = response.parsed_body.fetch("publication_work").sole
    expect(withdrawal_claim.fetch("work_id")).to eq(withdrawal.work_id)
    put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/failure.json",
        headers: headers(correlation: "same-target-withdrawal-failure"),
        params: {
          lease_token: withdrawal_claim.fetch("lease_token"),
          error_code: "destination_unavailable",
          error_detail: "Articles cleanup is waiting for a corrected destination.",
          failed_at: Time.zone.now.iso8601(6),
          correlation_id: "same-target-withdrawal-failure",
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(withdrawal.reload.state).to eq("retry_wait")

    claim(correlation: "same-target-surviving-restoration")
    surviving_claim = response.parsed_body.fetch("publication_work").sole
    expect(surviving_claim.fetch("work_id")).to eq(surviving_restoration.work_id)
    put "/discussion-bridge/v1/publication-work/#{surviving_restoration.work_id}/acknowledgement.json",
        headers: headers(correlation: "same-target-surviving-restored"),
        params: acknowledgement(
          surviving_claim,
          record,
          correlation: "same-target-surviving-restored",
          publication_revision: "wordpress:archive:same-target:PB",
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(withdrawal.reload.state).to eq("retry_wait")

    moved_policy_a = policy_a.deep_dup
    moved_policy_a["container_mapping"]["destination"] = "site:news"
    @connection.update!(
      destination_policies: [moved_policy_a, policy_b],
      policy_revision: "policy:same-id-new-target",
    )
    DiscussionBridge::SourceRevisionMaterializer.call(
      record: record,
      connection: @connection,
      force_revision: true,
    )
    moved_target_work = @connection.publication_works.where(
      destination_policy_id: policy_a.fetch("destination_policy_id"),
      resolved_container: { "id" => "site:news", "kind" => "post_type" },
    ).where.not(state: %w[acknowledged superseded]).where.not(id: withdrawal.id).sole
    claim(correlation: "same-id-new-target-issued")
    moved_target_claim = response.parsed_body.fetch("publication_work").sole
    expect(moved_target_claim).to include(
      "work_id" => moved_target_work.work_id,
      "destination_policy_id" => policy_a.fetch("destination_policy_id"),
      "resolved_container" => include("id" => "site:news"),
    )
    put "/discussion-bridge/v1/publication-work/#{moved_target_work.work_id}/acknowledgement.json",
        headers: headers(correlation: "same-id-new-target-complete"),
        params: acknowledgement(
          moved_target_claim,
          record,
          correlation: "same-id-new-target-complete",
          publication_revision: "wordpress:news:moved:PA-new-target",
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body

    travel_to(withdrawal.reload.next_retry_at + 1.second) do
      claim(correlation: "same-id-old-target-cleanup-retry")
      old_target_claim = response.parsed_body.fetch("publication_work").sole
      expect(old_target_claim).to include(
        "work_id" => withdrawal.work_id,
        "destination_policy_id" => policy_a.fetch("destination_policy_id"),
        "resolved_container" => include("id" => "site:articles"),
      )
      put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/failure.json",
          headers: headers(correlation: "same-id-old-target-cleanup-failure"),
          params: {
            lease_token: old_target_claim.fetch("lease_token"),
            error_code: "destination_unavailable",
            error_detail: "The old Articles target still requires cleanup.",
            failed_at: Time.zone.now.iso8601(6),
            correlation_id: "same-id-old-target-cleanup-failure",
          },
          as: :json
      expect(response).to have_http_status(:ok), response.body
    end
    expect(withdrawal.reload.state).to eq("retry_wait")

    @connection.update!(
      destination_policies: [policy_a, policy_b],
      policy_revision: "policy:same-target:restored",
    )
    DiscussionBridge::SourceRevisionMaterializer.call(
      record: record,
      connection: @connection,
      force_revision: true,
    )
    same_target_restoration = @connection.publication_works.where(
      destination_policy_id: policy_a.fetch("destination_policy_id"),
      action: %w[create update restore],
    ).where.not(state: %w[acknowledged superseded]).where.not(id: withdrawal.id).sole
    expect(same_target_restoration).to have_attributes(
      state: "available",
      may_have_materialized: false,
    )

    travel_to(withdrawal.reload.next_retry_at + 1.second) do
      claim(correlation: "same-target-queued-restoration-does-not-cancel")
      queued_restoration_cleanup = response.parsed_body.fetch("publication_work").sole
      expect(queued_restoration_cleanup.fetch("work_id")).to eq(withdrawal.work_id)
      put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/failure.json",
          headers: headers(correlation: "same-target-queued-restoration-cleanup-failure"),
          params: {
            lease_token: queued_restoration_cleanup.fetch("lease_token"),
            error_code: "destination_unavailable",
            error_detail: "Queued restoration has not yet made cleanup obsolete.",
            failed_at: Time.zone.now.iso8601(6),
            correlation_id: "same-target-queued-restoration-cleanup-failure",
          },
          as: :json
      expect(response).to have_http_status(:ok), response.body
    end
    expect(withdrawal.reload.state).to eq("retry_wait")

    claim(correlation: "same-target-restoration-issued")
    restored_claim = response.parsed_body.fetch("publication_work").sole
    expect(restored_claim).to include(
      "work_id" => same_target_restoration.work_id,
      "destination_policy_id" => policy_a.fetch("destination_policy_id"),
      "resolved_container" => include("id" => "site:articles"),
    )
    expect(same_target_restoration.reload.may_have_materialized).to be(true)
    put "/discussion-bridge/v1/publication-work/#{same_target_restoration.work_id}/acknowledgement.json",
        headers: headers(correlation: "same-target-restoration-complete"),
        params: acknowledgement(
          restored_claim,
          record,
          correlation: "same-target-restoration-complete",
          publication_revision: "wordpress:articles:restored:PA2",
        ),
        as: :json
    expect(response).to have_http_status(:ok), response.body

    travel_to(withdrawal.reload.next_retry_at + 1.second) do
      claim(correlation: "same-target-stale-cleanup-check")
      expect(response).to have_http_status(:ok), response.body
      claimed_ids = response.parsed_body.fetch("publication_work").map { |item| item.fetch("work_id") }
      expect(claimed_ids).not_to include(withdrawal.work_id)
      expect(withdrawal.reload).to have_attributes(
        state: "superseded",
        may_have_materialized: true,
      )
    end
    expect(@connection.publication_works.where(action: "unpublish")).to contain_exactly(withdrawal)
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
    _, source_post, record = create_source
    materialize_source
    claim(correlation: "issued-before-expiry", lease_seconds: 1)
    issued = DiscussionBridgePublicationWork.find_by!(
      work_id: response.parsed_body.fetch("publication_work").sole.fetch("work_id"),
    )
    expect(issued.may_have_materialized).to be(true)
    issued_destination = issued.resolved_container.deep_dup

    travel_to(2.seconds.from_now) do
      DiscussionBridge::PublicationWorkRegistry.new(connection: @connection).send(
        :reconcile_expired!,
        Time.zone.now,
      )
      expect(issued.reload).to have_attributes(state: "available", leased_at: nil, may_have_materialized: true)

      source_post.update_columns(
        cooked: "<p>Newer queued revision</p>",
        updated_at: 1.minute.from_now,
      )
      DiscussionBridge::SourceRevisionMaterializer.call(
        record: record,
        connection: @connection,
        force_revision: true,
      )
      queued = @connection.publication_works.order(:id).last
      queued_destination = { "id" => "site:never-issued", "kind" => "post_type" }
      queued.update_columns(resolved_container: queued_destination)
      expect(queued.reload).to have_attributes(
        state: "available",
        may_have_materialized: false,
        resolved_container: queued_destination,
      )

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
      resolved_container: issued_destination,
    )
    expect(withdrawal.resolved_container).not_to eq({ "id" => "site:never-issued", "kind" => "post_type" })

    travel_to(3.seconds.from_now) do
      claim(correlation: "retained-evidence-withdrawal")
      claimed_withdrawal = response.parsed_body.fetch("publication_work").sole
      expect(claimed_withdrawal).to include(
        "work_id" => withdrawal.work_id,
        "action" => "unpublish",
        "destination_policy_id" => issued.destination_policy_id,
        "resolved_container" => issued_destination,
      )
      put "/discussion-bridge/v1/publication-work/#{withdrawal.work_id}/acknowledgement.json",
          headers: headers(correlation: "retained-evidence-withdrawn"),
          params: acknowledgement(
            claimed_withdrawal,
            record,
            correlation: "retained-evidence-withdrawn",
          ),
          as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(withdrawal.reload.state).to eq("acknowledged")

      DiscussionBridge::SourceRevocationRegistry.reconcile_record!(
        record: record,
        connection: @connection.reload,
      )
      expect(@connection.publication_works.where(action: "unpublish").count).to eq(1)
    end
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
    end.to raise_error(ArgumentError, /temporarily unavailable/)
    expect(DiscussionBridge::ConnectionCapability.publication_readiness(@connection.reload)).to eq(
      :temporarily_unavailable,
    )
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

  it "returns temporary unavailability while an active native mapping is pending and resumes after approval" do
    catalog_revision = install_catalog
    topic, post, record = create_source
    materialize_source
    initial_revision = record.source_revisions.order(:source_revision_sequence).last
    expect(record.publication_works.sole.action).to eq("publish")

    approved_policy = @connection.destination_policies.sole.deep_stringify_keys
    pending_policy = approved_policy.deep_dup
    pending_policy["destination_policy_id"] = "destination:wordpress:pending"
    pending_policy["container_mapping"]["destination"] =
      DiscussionBridge::ConnectionCapability::PENDING_CATALOG_DESTINATION
    @connection.update!(
      destination_policies: [pending_policy],
      policy_revision: "policy:wordpress:pending",
    )
    expect(DiscussionBridge::ConnectionCapability.publication_readiness(@connection)).to eq(
      :temporarily_unavailable,
    )
    @connection.enabled = false
    expect(DiscussionBridge::ConnectionCapability.publication_readiness(@connection)).to eq(:direction_denied)
    @connection.reload.allowed_directions = ["to_discourse"]
    expect(DiscussionBridge::ConnectionCapability.publication_readiness(@connection)).to eq(:direction_denied)
    @connection.reload

    post.update!(raw: "Publication body after pending reset", cooked: "<p>Publication body after pending reset</p>")
    work_ids = @connection.publication_works.order(:id).pluck(:id)
    revision_ids = record.source_revisions.order(:id).pluck(:id)
    correlation = "pending-native-mapping"
    get "/discussion-bridge/v1/source-topics.json", headers: headers(correlation: correlation)
    expect(@connection.publication_works.order(:id).pluck(:id)).to eq(work_ids)
    expect(record.source_revisions.order(:id).pluck(:id)).to eq(revision_ids)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers.fetch("X-DiscussionBridge-Correlation")).to eq(correlation)
    expect(response.parsed_body).to include(
      "error_code" => "temporarily_unavailable",
      "correlation_id" => correlation,
    )

    get "/discussion-bridge/v1/source-topics/#{topic.id}.json",
        headers: headers(correlation: "pending-retained-detail"),
        params: { source_revision: initial_revision.source_revision }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("source_revision")).to eq(initial_revision.source_revision)

    get "/discussion-bridge/v1/source-revocations.json",
        headers: headers(correlation: "pending-retained-revocations")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("items")).to be_empty

    expect do
      DiscussionBridge::PublicationWorkRegistry.ensure_revision!(
        record: record,
        connection: @connection,
        revision: initial_revision,
      )
    end.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error) { |error|
      expect(error.error_code).to eq("temporarily_unavailable")
    }
    expect(@connection.publication_works.order(:id).pluck(:id)).to eq(work_ids)

    pending_topic = Fabricate(:topic, user: admin, category: category, visible: true)
    Fabricate(:post, topic: pending_topic, user: admin, post_number: 1, raw: "Pending local creation")
    expect do
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: pending_topic.id,
        external_id: "pending-local-creation",
        canonical_url: "https://publisher.example/articles/pending-local-creation/",
        lane: "articles",
      )
    end.to raise_error(ArgumentError, /temporarily unavailable/)
    expect(@connection.bridge_records.where(topic_id: pending_topic.id)).to be_empty

    approved_policy["catalog_revision"] = catalog_revision
    @connection.update!(
      destination_policies: [approved_policy],
      policy_revision: "policy:wordpress:approved",
    )
    expect(DiscussionBridge::ConnectionCapability.publication_readiness(@connection)).to eq(:active)

    correlation = "approved-native-mapping"
    get "/discussion-bridge/v1/source-topics.json", headers: headers(correlation: correlation)
    expect(response).to have_http_status(:ok), response.body
    expect(response.headers.fetch("X-DiscussionBridge-Correlation")).to eq(correlation)
    expect(response.parsed_body.fetch("correlation_id")).to eq(correlation)
    expect(record.reload.source_revisions.order(:id).pluck(:id)).not_to eq(revision_ids)
    resumed = record.publication_works.where(
      action: %w[publish update restore],
      policy_revision: "policy:wordpress:approved",
      source_revision: record.source_revisions.order(:source_revision_sequence).last.source_revision,
    ).sole
    expect(resumed.state).to eq("available")
    claim(correlation: "approved-native-mapping-claim")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("publication_work").sole.fetch("work_id")).to eq(resumed.work_id)
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
