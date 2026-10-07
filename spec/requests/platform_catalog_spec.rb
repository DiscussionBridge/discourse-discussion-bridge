# frozen_string_literal: true

require "rails_helper"
require_relative "../../db/migrate/20261007000002_retain_reconciled_destination_catalogs"

describe "DiscussionBridge descriptive catalogs and approved destination policy" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:user)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Catalog test", platform: "ghost",
      allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
  end

  def headers
    { "X-DiscussionBridge-Connection" => @connection.public_id, "X-DiscussionBridge-Secret" => @secret,
      "X-DiscussionBridge-Contract" => "0.2.0-alpha.22", "X-DiscussionBridge-Correlation" => "catalog-test", "HTTPS" => "on" }
  end

  def segments
    [
      { "segment_type" => "containers", "items" => [{ "id" => "posts", "name" => "Posts", "kind" => "post", "available" => true }] },
      { "segment_type" => "taxonomies", "items" => [{ "id" => "tags", "name" => "Tags", "hierarchical" => false, "available" => true }] },
      { "segment_type" => "terms", "items" => [{ "id" => "impact", "taxonomy_id" => "tags", "name" => "Impact", "parent_id" => nil, "available" => true }] },
      { "segment_type" => "authors", "items" => [{ "id" => "editor", "name" => "Editor", "available" => true }] },
      { "segment_type" => "presentation_modes", "items" => [{ "id" => "interactive", "name" => "Interactive", "available" => true }] },
      { "segment_type" => "native_limits", "items" => [{ "id" => "body", "name" => "Body", "maximum_bytes" => 500_000,
        "overflow_behavior" => "excerpt_with_read_more", "available" => true }] },
    ]
  end

  def catalog_update(items = segments, base: nil, name: nil, **overrides)
    current = DiscussionBridge::PlatformCatalog.current(@connection, @connection.platform)
    value = { "platform_profile" => @connection.platform, "base_catalog_revision" => base || current&.public_id || "catalog:empty",
      "segments" => items, "correlation_id" => "catalog-test" }.merge(overrides.stringify_keys)
    put "/discussion-bridge/v1/platform-catalog.json", params: JSON.generate(value), headers: headers.merge("CONTENT_TYPE" => "application/json")
    save(name, { request: value, response: response.parsed_body }) if name && response.status == 200
    response.parsed_body
  end

  def catalog_page(segment = "containers", name: nil, **query)
    get "/discussion-bridge/v1/platform-catalog.json", params: { platform_profile: @connection.platform,
      segment_type: segment }.merge(query), headers: headers
    save(name) if name
    response.parsed_body
  end

  def save(name, value = nil)
    directory = ENV["DISCUSSIONBRIDGE_CONTRACT_RECEIPTS"]
    return unless directory && name
    File.binwrite(File.join(directory, name), value ? JSON.generate(value) : response.body)
  end

  def definition(id: "primary", revision: nil)
    { "destination_policy_id" => id, "profile" => @connection.platform, "presentation_mode" => "interactive",
      "container_mapping" => { "source" => "forum", "destination" => "posts" },
      "taxonomy_mapping" => { "mode" => "mapped_only", "items" => [{ "source" => "category:42", "destination" => "impact" }] },
      "author_mapping" => { "mode" => "source_attribution", "destination_id" => "editor" },
      "native_limit_policy" => { "maximum_bytes" => 500_000, "overflow_behavior" => "excerpt_with_read_more" },
      "catalog_revision" => revision || DiscussionBridge::PlatformCatalog.current(@connection, @connection.platform).public_id }
  end

  def approve(value = definition, actor: admin)
    DiscussionBridge::DestinationPolicy.approve!(connection: @connection, definition: value, actor: actor)
  end

  def expect_error(code, status)
    expect(response).to have_http_status(status), response.body
    expect(response.parsed_body).to include("error_code" => code, "correlation_id" => "catalog-test")
    expect(response.headers["X-DiscussionBridge-Correlation"]).to eq("catalog-test")
  end

  it "returns an empty terminal catalog without a write" do
    value = catalog_page(name: "catalog-empty.json")
    expect(value).to include("items" => [], "complete" => true, "next_cursor" => nil, "catalog_revision" => "catalog:empty")
    expect(response.headers["Cache-Control"]).to eq("private, must-revalidate")
    expect(DiscussionBridgeCatalogRevision.count).to eq(0)
    expect(DiscussionBridgeDestinationPolicy.count).to eq(0)
  end

  it "publishes descriptive segments without changing connection scope, source or bindings" do
    attributes = @connection.attributes
    value = catalog_update(name: "catalog-update.json")
    expect(response).to have_http_status(:ok), response.body
    expect(value.fetch("accepted_segments")).to eq(segments.map { |segment| segment.fetch("segment_type") })
    expect(@connection.reload.attributes).to eq(attributes)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
    expect(DiscussionBridgeContentBinding.count).to eq(0)
    expect(DiscussionBridgeDestinationPolicy.count).to eq(0)
    segments.each { |segment| expect(catalog_page(segment.fetch("segment_type")).fetch("items")).to eq(segment.fetch("items")) }
    catalog_page(name: "catalog-containers.json")
  end

  it "atomically replaces only supplied complete segments and preserves immutable versions" do
    first = catalog_update.fetch("catalog_revision")
    original = DiscussionBridgeCatalogRevision.find_by!(public_id: first)
    before = original.catalog_items.order(:id).map(&:attributes)
    catalog_update([{ "segment_type" => "containers", "items" => [] }], name: "catalog-replace.json")
    expect(catalog_page.fetch("items")).to eq([])
    expect(catalog_page("authors").fetch("items")).to eq(segments[3].fetch("items"))
    expect(original.catalog_items.order(:id).map(&:attributes)).to eq(before)
    expect { original.update!(public_id: "changed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { original.catalog_items.first.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "fails stale compare-and-swap before any catalog or policy mutation" do
    revision = catalog_update.fetch("catalog_revision")
    catalog_update(base: "catalog:empty", name: nil)
    expect_error("catalog_revision_conflict", 409)
    expect(DiscussionBridgeCatalogRevision.count).to eq(1)
    expect(DiscussionBridge::PlatformCatalog.current(@connection, "ghost").public_id).to eq(revision)
    save("catalog-conflict.json")
  end

  it "paginates a pinned segment with finite real progress and an exact terminal pair" do
    items = (1..5).map { |id| { "id" => "author:#{id}", "name" => "Author #{id}", "available" => true } }
    revision = catalog_update([{ "segment_type" => "authors", "items" => items }]).fetch("catalog_revision")
    value = catalog_page("authors", limit: 2, name: "catalog-page-1.json")
    all = value.fetch("items")
    expect(value).to include("complete" => false)
    expect(value.fetch("next_cursor")).to be_present
    value = catalog_page("authors", limit: 2, catalog_revision: revision, cursor: value.fetch("next_cursor"), name: "catalog-page-2.json")
    all += value.fetch("items")
    value = catalog_page("authors", limit: 2, catalog_revision: revision, cursor: value.fetch("next_cursor"), name: "catalog-page-3.json")
    all += value.fetch("items")
    expect(all).to eq(items)
    expect(value).to include("complete" => true, "next_cursor" => nil)
  end

  it "never continues a cursor after revision, segment, connection scope or token changes" do
    catalog_update
    # Use two items to establish a nonterminal cursor.
    catalog_update([{ "segment_type" => "authors", "items" => (1..2).map { |id| { "id" => id.to_s, "name" => id.to_s, "available" => true } } }])
    value = catalog_page("authors", limit: 1)
    cursor, revision = value.values_at("next_cursor", "catalog_revision")
    catalog_page("containers", cursor: cursor, catalog_revision: revision)
    expect_error("cursor_snapshot_mismatch", 409)
    catalog_page("authors", cursor: cursor + "tamper", catalog_revision: revision)
    expect_error("cursor_snapshot_mismatch", 409)
    @connection.update!(allowed_lanes: ["changed"])
    catalog_page("authors", cursor: cursor, catalog_revision: revision)
    expect_error("cursor_snapshot_mismatch", 409)
    catalog_update
    catalog_page("authors", cursor: cursor, catalog_revision: revision)
    expect_error("catalog_revision_conflict", 409)
    save("catalog-cursor-conflict.json")
  end

  it "keeps the whole GET body bounded for escaped Unicode fields and real cursor progress" do
    items = (1..100).map { |id| { "id" => "#{id}:#{'"' * 245}", "name" => ('漢' * 30) + ('"' * 110),
      "kind" => '"' * 100, "available" => true } }
    # One complete segment must also fit the PUT envelope, so build the native
    # fixture directly to exercise the independent bounded GET boundary.
    revision = DiscussionBridgeCatalogRevision.create!(content_connection: @connection, platform_profile: "ghost",
      public_id: "catalog:wide", created_at: Time.now.utc)
    items.each { |item| revision.catalog_items.create!(segment_type: "containers", item_id: item.fetch("id"), value: item) }
    value = catalog_page(limit: 100, name: "catalog-wide-page-1.json")
    expect(response.body.bytesize).to be <= 65_536
    expect(value.fetch("items").size).to be_between(1, 99)
    expect(value).to include("complete" => false)
    first = value.fetch("items")
    value = catalog_page(limit: 100, cursor: value.fetch("next_cursor"), catalog_revision: "catalog:wide", name: "catalog-wide-page-2.json")
    expect(first + value.fetch("items")).to eq(items)
    expect(value).to include("complete" => true, "next_cursor" => nil)
  end

  it "rejects wrong profiles, credentials, disabled connections and old contract headers" do
    catalog_page(platform_profile: "wordpress")
    expect_error("scope_denied", 403)
    @secret = "wrong-credential-that-is-not-real-123456"
    catalog_update
    expect_error("authentication_failed", 401)
    @secret = @connection.rotate_secret!
    @connection.update!(enabled: false)
    catalog_page
    expect_error("authentication_failed", 401)
    @connection.update!(enabled: true)
    get "/discussion-bridge/v1/platform-catalog.json", params: { platform_profile: "ghost", segment_type: "authors" },
      headers: headers.merge("X-DiscussionBridge-Contract" => "0.2.0-alpha.21")
    expect_error("contract_version_mismatch", 401)
    save("catalog-auth-error.json")
    expect(DiscussionBridgeCatalogRevision.count).to eq(0)
  end

  it "rejects duplicate raw keys and actual oversized whitespace before framework parameter parsing" do
    put "/discussion-bridge/v1/platform-catalog.json", params: '{"segments":[],"segments":[]}', headers: headers.merge("CONTENT_TYPE" => "application/json")
    expect_error("invalid_json", 400)
    save("catalog-duplicate-error.json")
    put "/discussion-bridge/v1/platform-catalog.json", params: " " * 65_537, headers: headers.merge("CONTENT_TYPE" => "application/json")
    expect_error("request_too_large", 413)
    save("catalog-too-large-error.json")
    expect(DiscussionBridgeCatalogRevision.count).to eq(0)
  end

  it "rejects unknown fields, partial pages, duplicate IDs, invalid modes and bad typed values atomically" do
    variants = [segments + [segments.first], [{ "segment_type" => "containers", "items" => segments.first.fetch("items") * 2 }],
      [{ "segment_type" => "authors", "items" => (1..101).map { |id| { "id" => id.to_s, "name" => id.to_s, "available" => true } } }],
      [{ "segment_type" => "presentation_modes", "items" => [{ "id" => "invalid-mode", "name" => "Bad", "available" => true }] }],
      [{ "segment_type" => "authors", "items" => [{ "id" => "a", "name" => "A", "available" => "true" }] }]]
    variants.each do |items|
      catalog_update(items)
      expect_error("validation_failed", 422)
    end
    catalog_update([segments.first.merge("next_cursor" => "partial")])
    expect_error("unknown_field", 400)
    catalog_update(extra: "not declared")
    expect_error("unknown_field", 400)
    catalog_update(correlation_id: "different")
    expect_error("validation_failed", 422)
    expect(DiscussionBridgeCatalogRevision.count).to eq(0)
  end

  it "rejects missing taxonomy, wrong parents and cycles without a partial version" do
    bad = segments.deep_dup
    bad[2]["items"][0]["taxonomy_id"] = "missing"
    catalog_update(bad)
    expect_error("validation_failed", 422)
    bad = segments.deep_dup
    bad[2]["items"][0]["parent_id"] = "impact"
    catalog_update(bad)
    expect_error("validation_failed", 422)
    expect(DiscussionBridgeCatalogRevision.count).to eq(0)
  end

  it "does not reuse a removed stable container identity for a different native kind" do
    catalog_update
    catalog_update([{ "segment_type" => "containers", "items" => [] }])
    before = DiscussionBridgeCatalogRevision.count
    bad = segments.deep_dup
    bad.first["items"].first["kind"] = "page"
    catalog_update(bad)
    expect_error("identity_conflict", 409)
    expect(DiscussionBridgeCatalogRevision.count).to eq(before)
  end

  it "requires an actual native admin approval of an exact current catalog" do
    catalog_update
    original = @connection.attributes
    expect { approve(actor: user) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /policy_denied/)
    expect { approve(actor: moderator) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /policy_denied/)
    expect { approve(definition(revision: "catalog:old")) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /catalog_revision_conflict/)
    policy = approve
    expect(policy).to have_attributes(approved_by_id: admin.id, destination_policy_id: "primary", platform_profile: "ghost")
    expect(@connection.reload.attributes).to eq(original)
    expect(approve.id).to eq(policy.id)
    expect(DiscussionBridgeDestinationPolicy.count).to eq(1)
    expect { policy.update!(definition: {}) }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "preserves unavailable mapping references without silently changing the approved policy" do
    catalog_update
    policy = approve
    original = policy.attributes
    value = catalog_update([{ "segment_type" => "containers", "items" => [] },
      { "segment_type" => "authors", "items" => [] }, { "segment_type" => "terms", "items" => [] },
      { "segment_type" => "native_limits", "items" => [] }], name: "catalog-referenced-removal.json")
    expect(response).to have_http_status(:ok), response.body
    expect(catalog_page.fetch("items").sole).to include("id" => "posts", "available" => false)
    expect(catalog_page("authors").fetch("items").sole).to include("id" => "editor", "available" => false)
    expect(catalog_page("native_limits").fetch("items").sole).to include("maximum_bytes" => 500_000, "available" => false)
    expect(policy.reload.attributes).to eq(original)
    expect { approve(definition(revision: value.fetch("catalog_revision"))) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /policy_denied/)
    expect(DiscussionBridgeDestinationPolicy.count).to eq(1)
  end

  it "keeps independent policy revisions and their original approval/history" do
    catalog_update
    primary = approve
    secondary = approve(definition(id: "secondary"))
    catalog_update
    replacement = approve
    expect(replacement.policy_revision).not_to eq(primary.policy_revision)
    expect(DiscussionBridgeDestinationPolicy.current(@connection).map(&:id)).to match_array([replacement.id, secondary.id])
    expect(primary.reload.definition.fetch("catalog_revision")).not_to eq(replacement.definition.fetch("catalog_revision"))
    expect(secondary.reload.definition).to eq(definition(id: "secondary", revision: primary.definition.fetch("catalog_revision")))
    expect(DiscussionBridgeContentBinding.count).to eq(0)
  end

  it "configures policy through the native authenticated admin route, not adapter credentials" do
    catalog_update
    path = "/discussion-bridge/admin/content-connections/#{@connection.id}/destination-policies.json"
    put path, params: { destination_policy: definition }, as: :json, headers: headers
    expect(response).to have_http_status(:forbidden)
    sign_in(admin)
    put path, params: { destination_policy: definition }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("destination_policy")).to eq(definition)
    expect(DiscussionBridgeDestinationPolicy.count).to eq(1)
  end

  it "fails an interrupted catalog transaction without committing partial items or changing approval" do
    catalog_update
    policy = approve
    before = [DiscussionBridgeCatalogRevision.count, DiscussionBridgeCatalogItem.count, policy.attributes]
    allow_any_instance_of(DiscussionBridgeCatalogItem).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, "synthetic transaction interruption")
    catalog_update
    expect_error("internal_error", 500)
    expect([DiscussionBridgeCatalogRevision.count, DiscussionBridgeCatalogItem.count, policy.reload.attributes]).to eq(before)
    save("catalog-rollback-error.json")
  end

  it "uses the same catalog and policy implementation for all seven publishing profiles" do
    %w[astro ghost hugo statamic_flat statamic_db statamic_ssg wordpress].each do |profile|
      platform = profile.start_with?("statamic_") ? "statamic" : profile
      @connection, @secret = DiscussionBridgeContentConnection.issue!(name: "Profile #{profile}", platform: platform,
        allowed_origins: ["https://native.example"], allowed_directions: ["from_discourse"], allowed_lanes: [])
      value = catalog_update(platform_profile: profile)
      expect(response).to have_http_status(:ok), response.body
      policy = definition(revision: value.fetch("catalog_revision")).merge("profile" => profile)
      expect(approve(policy).platform_profile).to eq(profile)
      catalog_page(platform_profile: profile)
      expect(response).to have_http_status(:ok), response.body
    end
    expect(DiscussionBridgeDestinationPolicy.count).to eq(7)
    expect(DiscussionBridgeContentBinding.count).to eq(0)
  end

  it "rejects unavailable or invented native mappings, duplicate source mappings and undeclared mode changes" do
    catalog_update
    original = definition
    bad = original.deep_dup
    bad["container_mapping"]["destination"] = "missing"
    expect { approve(bad) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /policy_denied/)
    bad = original.deep_dup
    bad["taxonomy_mapping"]["items"] *= 2
    expect { approve(bad) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /validation_failed/)
    bad = original.deep_dup
    bad["native_limit_policy"]["maximum_bytes"] = 999_999
    expect { approve(bad) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /policy_denied/)
    bad = original.deep_dup
    bad["destination_mode"] = "static"
    expect { approve(bad) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /unknown_field/)
    bad = original.deep_dup
    bad["presentation_mode"] = "invalid-mode"
    expect { approve(bad) }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /validation_failed/)
    expect(DiscussionBridgeDestinationPolicy.count).to eq(0)
  end

  it "permits intentional many-to-one mapping without creating terms or accounts" do
    catalog_update
    value = definition
    value["taxonomy_mapping"]["items"] << { "source" => "category:43", "destination" => "impact" }
    policy = approve(value)
    expect(policy.definition.fetch("taxonomy_mapping").fetch("items").map { |item| item.fetch("destination") }).to eq(%w[impact impact])
    expect(DiscussionBridgeContentBinding.count).to eq(0)
    expect(DiscussionBridgeBridgeRecord.count).to eq(0)
  end

  it "refuses native policy approval after connection disable or direction revocation" do
    catalog_update
    @connection.update!(enabled: false)
    expect { approve }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /scope_denied/)
    @connection.update!(enabled: true, allowed_directions: ["to_discourse"])
    expect { approve }.to raise_error(DiscussionBridge::AdapterRequestBoundary::Error, /scope_denied/)
    expect(DiscussionBridgeDestinationPolicy.count).to eq(0)
  end

  it "refuses populated schema rollback without erasing catalog or approved policy history" do
    catalog_update
    approve
    before = [DiscussionBridgeCatalogRevision.count, DiscussionBridgeCatalogItem.count, DiscussionBridgeDestinationPolicy.count]
    expect { RetainReconciledDestinationCatalogs.new.down }.to raise_error(ActiveRecord::IrreversibleMigration, /Retain catalogs/)
    expect([DiscussionBridgeCatalogRevision.count, DiscussionBridgeCatalogItem.count, DiscussionBridgeDestinationPolicy.count]).to eq(before)
  end
end
