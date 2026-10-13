# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::AdapterBridgeRecordsController do
  fab!(:service_actor, :admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = service_actor.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Revisioned source",
        platform: "wordpress",
        allowed_origins: ["https://example.com"],
        allowed_directions: ["to_discourse"],
        allowed_lanes: [],
      )
  end

  def headers
    {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => @secret,
    }
  end

  def payload(
    html: "<p>Authoritative native source body</p>",
    title: "An authoritative source article",
    previous: nil,
    revision: nil,
    authors: nil,
    primary: nil,
    legacy: false,
    publication: {}
  )
    data = {
      direction: "to_discourse",
      external_id: "native-source-1",
      canonical_url: "https://example.com/articles/source/",
      title: title,
      content_html: html,
      published: true,
      visibility: "unlisted",
      adapter_id: "wordpress-official",
      adapter_version: "test",
    }
    data[:source_authors] = authors if authors
    data[:primary_source_author_id] = primary if primary
    unless legacy
      metadata = {
        revision:
          revision || Digest::SHA256.hexdigest(JSON.generate([title, html, authors, primary])),
        previous_revision: previous,
        created_at: "2026-09-01T08:00:00.000000Z",
        updated_at: "2026-09-02T08:00:00.000000Z",
        content_sha256: Digest::SHA256.hexdigest(html),
        content_bytes: html.bytesize,
        excerpted: false,
      }.merge(publication)
      data[:source_publication] = metadata
    end
    { bridge_record: data }
  end

  def resolve(data)
    post "/discussion-bridge/v1/bridge-records/resolve.json",
         headers: headers,
         params: data,
         as: :json
  end

  it "creates an explicit receipt and retries it without rewriting the native post" do
    data = payload
    resolve(data)
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body).to include(
      "source_publication_outcome" => "created",
      "source_revision" => data.dig(:bridge_record, :source_publication, :revision),
    )
    record = DiscussionBridgeBridgeRecord.last
    first_post = record.topic.first_post
    raw = first_post.raw
    version = first_post.version
    metadata = record.source_publication
    expect(metadata.fetch("managed_native_sha256")).to eq(
      DiscussionBridge::SourcePublication.managed_native_sha256(record.topic, first_post),
    )
    data[:bridge_record][:source_publication][:previous_revision] = metadata.fetch("revision")
    resolve(data)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      "outcome" => "resolved",
      "source_publication_outcome" => "unchanged",
    )
    expect(first_post.reload).to have_attributes(raw: raw, version: version)
    expect(record.reload.source_publication).to eq(metadata)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end

  it "updates the same resource, topic, first post and binding through native revision" do
    initial = payload
    resolve(initial)
    record = DiscussionBridgeBridgeRecord.last
    topic = record.topic
    first_post = topic.first_post
    binding = record.active_binding("source")
    original_version = first_post.version
    changed =
      payload(
        html: "<p>Updated source content</p>",
        title: "Updated authoritative source title",
        previous: initial.dig(:bridge_record, :source_publication, :revision),
      )
    resolve(changed)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      "resource_id" => record.resource_id,
      "topic_id" => topic.id,
      "source_publication_outcome" => "updated",
    )
    expect(topic.reload.title).to eq("Updated authoritative source title")
    expect(first_post.reload.raw).to include(
      "Updated source content",
      "https://example.com/articles/source/",
    )
    expect(first_post.version).to be > original_version
    expect(record.reload.active_binding("source").id).to eq(binding.id)
    expect(record.topic_id).to eq(topic.id)
    expect(topic.visible).to eq(false)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end

  it "leaves legacy resolution as identity lookup even when the supplied snapshot changed" do
    resolve(payload)
    record = DiscussionBridgeBridgeRecord.last
    first_post = record.topic.first_post
    before = [record.title, first_post.raw, first_post.version, record.source_publication]
    resolve(
      payload(
        html: "<p>Legacy snapshot must not rewrite native content</p>",
        title: "A different legacy title",
        legacy: true,
      ),
    )
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key("source_publication_outcome")
    expect(
      [record.reload.title, first_post.reload.raw, first_post.version, record.source_publication],
    ).to eq(before)
  end

  it "refuses stale CAS and conflicting input for an accepted revision" do
    initial = payload
    resolve(initial)
    record = DiscussionBridgeBridgeRecord.last
    first = initial.dig(:bridge_record, :source_publication, :revision)
    changed = payload(html: "<p>Current second edition</p>", previous: first)
    resolve(changed)
    current = record.reload.source_publication
    raw = record.topic.first_post.raw
    resolve(payload(html: "<p>Stale third edition</p>", previous: first))
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("reason" => "source_publication_revision_conflict")
    conflicting = changed.deep_dup
    conflicting[:bridge_record][:title] = "A changed title with an old revision"
    resolve(conflicting)
    expect(response).to have_http_status(:conflict)
    expect(record.reload.source_publication).to eq(current)
    expect(record.topic.first_post.raw).to eq(raw)
  end

  it "detects native human edits on exact retries and never overwrites them" do
    data = payload
    resolve(data)
    record = DiscussionBridgeBridgeRecord.last
    first_post = record.topic.first_post
    metadata = record.source_publication
    expect(
      first_post.revise(
        service_actor,
        { raw: "A forum-owned human edit must remain intact." },
        force_new_version: true,
      ),
    ).to eq(true)
    resolve(data)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("reason" => "managed_native_post_changed")
    expect(first_post.reload.raw).to eq("A forum-owned human edit must remain intact.")
    expect(record.reload.source_publication).to eq(metadata)
  end

  it "adopts exact legacy content without rewriting and refuses a different legacy snapshot" do
    resolve(payload(legacy: true))
    record = DiscussionBridgeBridgeRecord.last
    first_post = record.topic.first_post
    before = [first_post.raw, first_post.version]
    resolve(payload(html: "<p>Changed source cannot blanket-adopt a legacy native post</p>"))
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("reason" => "source_publication_adoption_conflict")
    expect(record.reload.source_publication).to be_nil
    resolve(payload)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include("source_publication_outcome" => "adopted")
    expect([first_post.reload.raw, first_post.version]).to eq(before)
  end

  it "retains unknown native dates as null without inventing a synchronization date" do
    resolve(payload(publication: { created_at: nil, updated_at: nil }))
    expect(response).to have_http_status(:created), response.body
    expect(DiscussionBridgeBridgeRecord.last.source_publication).to include(
      "created_at" => nil,
      "updated_at" => nil,
    )
  end

  it "accepts a valid bounded excerpt with a canonical Read More and full-source digest" do
    full = "<p>#{"Large native source. " * 4_000}</p>"
    excerpt =
      '<p>Selected source excerpt.</p><p><a href="https://example.com/articles/source/">Read More</a></p>'
    resolve(
      payload(
        html: excerpt,
        publication: {
          excerpted: true,
          content_bytes: full.bytesize,
          content_sha256: Digest::SHA256.hexdigest(full),
        },
      ),
    )
    expect(response).to have_http_status(:created), response.body
    expect(DiscussionBridgeBridgeRecord.last.source_publication.fetch("content_bytes")).to be >
      49_152
  end

  it "rejects malformed receipts, digest mismatches, unsafe dates and excerpts without creating content" do
    invalid = [
      { revision: "INVALID" },
      { content_bytes: 0 },
      { excerpted: "false" },
      { content_sha256: "0" * 64 },
      { updated_at: "2026-08-01T08:00:00Z" },
      { created_at: "2026-02-30T08:00:00Z" },
      { created_at: "2026-09-01" },
      { excerpted: true },
      { managed_native_sha256: "0" * 64 },
    ]
    invalid.each do |metadata|
      resolve(payload(publication: metadata))
      expect(response).to have_http_status(:unprocessable_entity), response.body
    end
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "applies a newly selected mapped native author on an explicitly revisioned update" do
    first_author = Fabricate(:user)
    next_author = Fabricate(:user)
    @connection.update!(authorship_mode: "mapped", unmapped_author_policy: "hold")
    @connection.source_authors.create!(
      source_author_id: "source:first",
      display_name: "First source author",
      discourse_user_id: first_author.id,
      last_seen_at: Time.zone.now,
    )
    @connection.source_authors.create!(
      source_author_id: "source:next",
      display_name: "Next source author",
      discourse_user_id: next_author.id,
      last_seen_at: Time.zone.now,
    )
    initial =
      payload(
        authors: [{ id: "source:first", name: "First source author" }],
        primary: "source:first",
      )
    resolve(initial)
    expect(response).to have_http_status(:created), response.body
    record = DiscussionBridgeBridgeRecord.last
    post_id = record.topic.first_post.id
    binding_id = record.active_binding("source").id
    update =
      payload(
        authors: [{ id: "source:next", name: "Next source author" }],
        primary: "source:next",
        previous: initial.dig(:bridge_record, :source_publication, :revision),
      )
    resolve(update)
    expect(response).to have_http_status(:ok), response.body
    expect(record.reload.effective_actor_id).to eq(next_author.id)
    expect(record.topic.first_post).to have_attributes(id: post_id, user_id: next_author.id)
    expect(record.active_binding("source").id).to eq(binding_id)
    expect(record.source_authors.first.fetch("id")).to eq("source:next")
  end

  it "refuses an author change when the native operating moderator lacks ownership permission" do
    initial = payload
    resolve(initial)
    record = DiscussionBridgeBridgeRecord.last
    first_post = record.topic.first_post
    receipt = record.source_publication
    raw = first_post.raw
    service_actor.update!(admin: false, moderator: true)
    SiteSetting.moderators_change_post_ownership = false
    SiteSetting.change_post_ownership_allowed_groups = ""
    @connection.update!(author_user: Fabricate(:user))

    resolve(
      payload(
        html: "<p>A source update requiring another owner</p>",
        previous: initial.dig(:bridge_record, :source_publication, :revision),
      ),
    )

    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(response.parsed_body).to include("reason" => "native_author_change_denied")
    expect(first_post.reload).to have_attributes(raw: raw, user_id: service_actor.id)
    expect(record.reload.source_publication).to eq(receipt)
  end

  it "rolls back the native revision if its publication receipt cannot be persisted" do
    initial = payload
    resolve(initial)
    record = DiscussionBridgeBridgeRecord.last
    first_post = record.topic.first_post
    before = [record.topic.title, first_post.raw, first_post.version, record.source_publication]
    DiscussionBridge::SourcePublication.stubs(:receipt).raises(
      ArgumentError,
      "Injected receipt failure",
    )

    resolve(
      payload(
        html: "<p>A new native source edition</p>",
        title: "A new source title",
        previous: initial.dig(:bridge_record, :source_publication, :revision),
      ),
    )

    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(
      [
        record.topic.reload.title,
        first_post.reload.raw,
        first_post.version,
        record.reload.source_publication,
      ],
    ).to eq(before)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
  end
end
