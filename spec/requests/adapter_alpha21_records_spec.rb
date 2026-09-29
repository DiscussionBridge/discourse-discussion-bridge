# frozen_string_literal: true

require "rails_helper"

describe "DiscussionBridge Adapter Protocol Alpha.21 records" do
  fab!(:service_actor, :admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = service_actor.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Alpha.21 WordPress",
      platform: "wordpress",
      allowed_origins: ["https://publisher.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: ["articles"],
      destination_policies: [destination_policy],
      catalog_required: false,
      policy_revision: "policy:2026-09-27:2",
    )
  end

  def destination_policy
    {
      "destination_policy_id" => "destination:discourse:articles:1",
      "profile" => "discourse_as_publisher",
      "presentation_mode" => "interactive",
      "container_mapping" => {
        "source" => "site:articles",
        "destination" => "discourse:category:articles",
      },
      "taxonomy_mapping" => { "mode" => "mapped_only" },
      "author_mapping" => { "mode" => "source_attribution" },
      "native_limit_policy" => {
        "maximum_bytes" => 49_152,
        "overflow_behavior" => "excerpt_with_read_more",
      },
      "catalog_revision" => "catalog:discourse:2026-09-27:1",
    }
  end

  def headers(correlation: "alpha21-record-1")
    {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => DiscussionBridge::CONTRACT_VERSION,
      "X-DiscussionBridge-Correlation" => correlation,
      "HTTPS" => "on",
    }
  end

  def payload(content_html: "<p>Authoritative article revision.</p>", correlation: "alpha21-record-1", **overrides)
    record = {
      direction: "to_discourse",
      external_id: "post:site-7:482",
      canonical_url: "https://publisher.example/articles/community-guide/",
      title: "Community Guide",
      content_html: content_html,
      published: true,
      presentation_mode: "interactive",
      source_revision: "wordpress:post:482:revision:9",
      source_revision_sequence: 9,
      source_created_at: "2026-09-01T16:00:00Z",
      source_updated_at: "2026-09-27T18:30:00Z",
      content_disposition: "complete",
      source_content_bytes: content_html.bytesize,
      source_content_sha256: Digest::SHA256.hexdigest(content_html),
      visibility: "unlisted",
      lane: "articles",
      correlation_id: correlation,
    }.merge(overrides)
    { bridge_record: record }
  end

  it "reports the exact stored effective connection capability without expanding scope" do
    get "/discussion-bridge/v1/connection.json", headers: headers(correlation: "capability-1")

    expect(response).to have_http_status(:ok), response.body
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    expect(response.parsed_body.keys).to contain_exactly(
      "contract_version",
      "connection_id",
      "enabled",
      "directions",
      "lanes",
      "allowed_presentation_modes",
      "supported_operations",
      "bounds",
      "destination_policies",
      "catalog_required",
      "policy_revision",
      "correlation_id",
    )
    expect(response.parsed_body).to include(
      "connection_id" => @connection.public_id,
      "directions" => ["to_discourse"],
      "lanes" => ["articles"],
      "supported_operations" => ["resolve"],
      "destination_policies" => [destination_policy],
      "policy_revision" => "policy:2026-09-27:2",
      "correlation_id" => "capability-1",
    )
  end

  it "requires the bounded configured forum name for a From Discourse capability" do
    from_policy = destination_policy.merge(
      "destination_policy_id" => "destination:wordpress:articles:1",
      "profile" => "wordpress",
    )
    @connection.update!(allowed_directions: ["from_discourse"], destination_policies: [from_policy])
    previous = ENV.delete("DISCUSSIONBRIDGE_FORUM_NAME")
    get "/discussion-bridge/v1/connection.json", headers: headers(correlation: "capability-2")
    expect(response).to have_http_status(:service_unavailable)

    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "Community Forum"
    get "/discussion-bridge/v1/connection.json", headers: headers(correlation: "capability-3")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "forum_name" => "Community Forum",
      "supported_operations" => %w[resolve inventory claim renew acknowledge fail revocations catalog],
    )
  ensure
    previous.nil? ? ENV.delete("DISCUSSIONBRIDGE_FORUM_NAME") : ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = previous
  end

  it "creates, exactly replays, and revision-updates one stable topic with visible post history" do
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload,
         as: :json
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body).to include(
      "accepted_source_revision" => "wordpress:post:482:revision:9",
      "accepted_source_revision_sequence" => 9,
    )
    record = DiscussionBridgeBridgeRecord.last
    topic_id = record.topic_id
    post_id = record.topic.first_post.id
    initial_version = record.topic.first_post.version

    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload,
         as: :json
    expect(response).to have_http_status(:ok)
    expect(record.reload.topic.first_post.version).to eq(initial_version)

    updated_html = "<p>The wiki guide now includes the approved update.</p>"
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers(correlation: "alpha21-record-2"),
         params: payload(
           content_html: updated_html,
           correlation: "alpha21-record-2",
           source_revision: "wordpress:post:482:revision:10",
           source_revision_sequence: 10,
           source_updated_at: "2026-09-28T01:00:00Z",
         ),
         as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      "outcome" => "resolved",
      "accepted_source_revision_sequence" => 10,
      "topic_id" => topic_id,
    )
    record.reload
    expect(record).to have_attributes(
      topic_id: topic_id,
      source_revision: "wordpress:post:482:revision:10",
      source_revision_sequence: 10,
      source_content_sha256: Digest::SHA256.hexdigest(updated_html),
    )
    expect(record.topic.first_post).to have_attributes(id: post_id)
    expect(record.topic.first_post.version).to be > initial_version
    expect(record.topic.first_post.raw).to include("approved update")
    expect(PostRevision.where(post_id: post_id)).to exist
  end

  it "migrates a source URL only after verification, proves its ancestry, and reserves the retired URL" do
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload,
         as: :json
    expect(response).to have_http_status(:created), response.body
    record = DiscussionBridgeBridgeRecord.last
    binding = record.active_binding("source")
    old_url = binding.canonical_url
    new_url = "https://publisher.example/articles/community-guide-current/"
    TopicEmbed.create!(
      topic_id: record.topic_id,
      post_id: record.topic.first_post.id,
      embed_url: TopicEmbed.normalize_url(old_url),
    )

    allow(DiscussionBridge::PublicationRedirectVerifier).to receive(:call).and_return(308)
    sign_in(service_actor)
    put "/discussion-bridge/admin/bridge-records/#{record.id}/migrate-source-url.json",
        params: {
          migration: {
            old_url: old_url,
            new_url: new_url,
            external_id: binding.external_id,
            native_identity_confirmed: true,
          },
        },
        as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("outcome" => "migrated", "redirect_status" => 308)
    expect(binding.reload.canonical_url).to eq(new_url)
    expect(record.source_url_histories.sole).to have_attributes(
      old_canonical_url: old_url,
      new_canonical_url: new_url,
      redirect_status: 308,
      verified_by_id: service_actor.id,
    )
    expect(TopicEmbed.find_by!(topic_id: record.topic_id).embed_url).to eq(
      TopicEmbed.normalize_url(new_url),
    )

    sign_out
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}/source-url-proof.json",
        headers: headers(correlation: "source-url-proof-1"),
        params: { from_url: old_url, to_url: new_url }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      "resource_id" => record.resource_id,
      "external_id" => binding.external_id,
      "from_url" => old_url,
      "to_url" => new_url,
      "verified" => true,
      "transition_count" => 1,
    )
    expect(response.parsed_body.fetch("transitions").sole).to include(
      "old_url" => old_url,
      "new_url" => new_url,
      "redirect_status" => 308,
    )

    conflicting = payload(
      correlation: "retired-url-reuse-1",
      external_id: "post:site-7:retired-reuse",
      canonical_url: old_url,
      source_revision: "wordpress:post:retired-reuse:revision:1",
      source_revision_sequence: 1,
    )
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers(correlation: "retired-url-reuse-1"),
         params: conflicting,
         as: :json
    expect(response).to have_http_status(:gone)
    expect(response.parsed_body.fetch("error_code")).to eq("url_retired")
  end

  it "fails stale and same-sequence conflicting revisions closed without mutation" do
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    record = DiscussionBridgeBridgeRecord.last
    original_version = record.topic.first_post.version

    conflicting_html = "<p>Conflicting same-sequence content.</p>"
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload(content_html: conflicting_html, source_revision: "wordpress:post:482:revision:other"),
         as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("revision_conflict")

    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload(source_revision_sequence: 8, source_revision: "wordpress:post:482:revision:8"),
         as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("revision_conflict")
    expect(record.reload.source_revision_sequence).to eq(9)
    expect(record.topic.first_post.version).to eq(original_version)
  end

  it "admits an exact Alpha.21 revision onto a retained unversioned Alpha.30 identity" do
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    record = DiscussionBridgeBridgeRecord.last
    topic_id = record.topic_id
    record.update_columns(
      presentation_mode: nil,
      source_revision: nil,
      source_revision_sequence: nil,
      source_created_at: nil,
      source_updated_at: nil,
      content_disposition: nil,
      source_content_bytes: nil,
      source_content_sha256: nil,
      delivered_content_sha256: nil,
    )
    record.active_binding("source").update_columns(
      presentation_mode: nil,
      applied_source_revision: nil,
      publication_revision: nil,
      content_disposition: nil,
      synchronized_at: nil,
    )

    admitted_html = "<p>First contract-versioned revision after upgrade.</p>"
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers(correlation: "alpha21-admit-1"),
         params: payload(
           content_html: admitted_html,
           correlation: "alpha21-admit-1",
           source_revision: "wordpress:post:482:revision:10",
           source_revision_sequence: 10,
           source_updated_at: "2026-09-28T01:00:00Z",
         ),
         as: :json

    expect(response).to have_http_status(:ok), response.body
    expect(record.reload).to have_attributes(
      topic_id: topic_id,
      source_revision: "wordpress:post:482:revision:10",
      source_revision_sequence: 10,
    )
    expect(record.topic.first_post.raw).to include("First contract-versioned revision")
  end

  it "enforces the exact revision, timestamp, disposition, and source-content bounds" do
    cases = [
      [payload(presentation_mode: "fullInteractive"), :unprocessable_entity, "validation_failed"],
      [payload(source_content_bytes: 16_777_217), :unprocessable_entity, "validation_failed"],
      [payload(source_content_sha256: "0" * 64), :unprocessable_entity, "integrity_failed"],
      [payload(source_updated_at: "2026-09-27T18:30:00+00:00"), :bad_request, "malformed_value"],
      [payload(source_updated_at: "2026-02-30T18:30:00Z"), :bad_request, "malformed_value"],
      [payload(source_updated_at: "2026-09-27T24:00:00Z"), :bad_request, "malformed_value"],
    ]
    missing = payload
    missing[:bridge_record].delete(:source_revision)
    cases << [missing, :unprocessable_entity, "validation_failed"]

    cases.each do |body, status, code|
      post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: body, as: :json
      expect(response).to have_http_status(status)
      expect(response.parsed_body.fetch("error_code")).to eq(code)
    end
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "fails an unproved canonical URL change closed as reconciliation required" do
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json

    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload(canonical_url: "https://publisher.example/articles/renamed-guide/"),
         as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include(
      "outcome" => "reconciliation_required",
      "reason" => "binding_identity_conflict",
      "conflict_fields" => %w[external_id canonical_url],
    )
  end

  it "accepts bounded excerpt transport and preserves complete-source identity" do
    excerpt = <<~HTML.strip
      <p>This is a bounded excerpt of the complete guide.</p><p><a href="https://publisher.example/articles/community-guide/">Read More</a></p>
    HTML
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: payload(
           content_html: excerpt,
           content_disposition: "excerpt",
           source_content_bytes: 104_857,
           source_content_sha256: "a" * 64,
           read_more_url: "https://publisher.example/articles/community-guide/",
         ),
         as: :json

    expect(response).to have_http_status(:created), response.body
    expect(DiscussionBridgeBridgeRecord.last).to have_attributes(
      content_disposition: "excerpt",
      source_content_bytes: 104_857,
      source_content_sha256: "a" * 64,
    )
  end

  it "rejects comment-only, plain-text, and hidden excerpt notices or Read More references" do
    invalid_markup = [
      "<!-- excerpt --><p>Read More</p>",
      '<p>This excerpt is bounded. Read More</p>',
      '<p hidden>This excerpt is bounded.</p><a href="https://publisher.example/articles/community-guide/">Read More</a>',
      '<p>This excerpt is bounded.</p><a aria-hidden="true" href="https://publisher.example/articles/community-guide/">Read More</a>',
    ]

    invalid_markup.each_with_index do |content_html, index|
      correlation = "invalid-excerpt-#{index}"
      post "/discussion-bridge/v1/bridge-records/resolve.json",
           headers: headers(correlation: correlation),
           params: payload(
             content_html: content_html,
             correlation: correlation,
             content_disposition: "excerpt",
             source_content_bytes: content_html.bytesize + 1,
             source_content_sha256: "a" * 64,
             read_more_url: "https://publisher.example/articles/community-guide/",
           ),
           as: :json
      expect(response).to have_http_status(:unprocessable_entity),
                          "invalid excerpt index #{index} was accepted: #{content_html.inspect}; #{response.body}"
      expect(response.parsed_body.fetch("error_code")).to eq("validation_failed")
    end
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "preserves nanosecond wire timestamps and rejects a same-sequence lexical change" do
    exact = payload(
      source_created_at: "2026-09-01T16:00:00.123456789Z",
      source_updated_at: "2026-09-27T18:30:00.987654321Z",
    )
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: exact, as: :json
    expect(response).to have_http_status(:created), response.body
    record = DiscussionBridgeBridgeRecord.last
    expect(record).to have_attributes(
      source_created_at_wire: "2026-09-01T16:00:00.123456789Z",
      source_updated_at_wire: "2026-09-27T18:30:00.987654321Z",
    )

    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: exact, as: :json
    expect(response).to have_http_status(:ok)

    changed = payload(
      source_created_at: "2026-09-01T16:00:00.123456788Z",
      source_updated_at: "2026-09-27T18:30:00.987654321Z",
    )
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: changed, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error_code")).to eq("revision_conflict")
  end

  it "returns exact record index/detail fields and contract-shaped binding state" do
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: payload, as: :json
    resource_id = response.parsed_body.fetch("resource_id")

    get "/discussion-bridge/v1/bridge-records.json", headers: headers(correlation: "record-index-1")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.keys).to contain_exactly("records", "page", "total_pages", "correlation_id")
    record = response.parsed_body.fetch("records").sole
    expect(record.keys).to contain_exactly(
      "resource_id",
      "direction",
      "state",
      "title",
      "topic_id",
      "topic_url",
      "source_revision",
      "source_revision_sequence",
      "source_created_at",
      "source_updated_at",
      "content_disposition",
      "bindings",
    )
    binding = record.fetch("bindings").sole
    expect(binding.keys).to contain_exactly(
      "binding_id",
      "connection_id",
      "role",
      "state",
      "external_id",
      "canonical_url",
      "presentation_mode",
      "applied_source_revision",
      "publication_revision",
      "content_disposition",
      "synchronized_at",
      "deployment_state",
      "verification_state",
    )
    expect(binding).to include(
      "connection_id" => @connection.public_id,
      "role" => "source",
      "state" => "active",
      "presentation_mode" => "interactive",
      "deployment_state" => "not_required",
      "verification_state" => "not_required",
    )

    get "/discussion-bridge/v1/bridge-records/#{resource_id}.json",
        headers: headers(correlation: "record-show-1")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.keys).to contain_exactly("bridge_record", "correlation_id")
    expect(response.parsed_body.dig("bridge_record", "resource_id")).to eq(resource_id)
  end

  it "preserves long valid wire timestamps and omits absent optional event fields" do
    timestamp = "2026-09-01T16:00:00.12345678901234567890Z"
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers,
         params: payload(source_created_at: timestamp), as: :json
    expect(response).to have_http_status(:created)
    record = DiscussionBridgeBridgeRecord.last
    expect(record.source_created_at_wire).to eq(timestamp)
    get "/discussion-bridge/v1/bridge-records/#{record.resource_id}.json",
        headers: headers(correlation: "long-timestamp-detail-1")
    expect(response).to have_http_status(:ok), response.body
    binding = response.parsed_body.dig("bridge_record", "bindings").sole
    expect(binding).not_to have_key("deployed_at")
    expect(binding).not_to have_key("publicly_verified_at")
  end

  it "rejects excerpt disclosures hidden by CSS, ARIA, or a closed details element" do
    url = "https://publisher.example/articles/community-guide/"
    hidden = [
      %(<div style="display:none"><p>Excerpt</p><a href="#{url}">Read More</a></div>),
      %(<div style="visibility:hidden"><p>Excerpt</p><a href="#{url}">Read More</a></div>),
      %(<div aria-hidden="TRUE"><p>Excerpt</p><a href="#{url}">Read More</a></div>),
      %(<details><summary>More information</summary><p>Excerpt</p><a href="#{url}">Read More</a></details>),
      %(<p>This excerpt is bounded.</p><a href="#{url}"><details><summary></summary><span>Read More</span></details></a>),
    ]
    hidden.each do |html|
      expect(DiscussionBridge::BridgeRecordRequest.send(:valid_excerpt_markup?, html, url)).to be(false)
    end

    body = payload(
      content_html: hidden.last,
      content_disposition: "excerpt",
      source_content_bytes: 60_000,
      source_content_sha256: "a" * 64,
      read_more_url: url,
    )
    post "/discussion-bridge/v1/bridge-records/resolve.json", headers: headers, params: body, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)

    visible_formatted = %(<p>This excerpt is bounded.</p><a href="#{url}">Read <strong>More</strong></a>)
    expect(
      DiscussionBridge::BridgeRecordRequest.send(:valid_excerpt_markup?, visible_formatted, url),
    ).to be(true)
  end
end
