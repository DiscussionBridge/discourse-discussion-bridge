# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsCatalogStore do
  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    @now = Time.current
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS catalog author fixture",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    @configuration = {
      "profile" => "ghost",
      "destination_origin" => "https://site.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "native:fixture",
        "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic",
        "complete_content_supported" => true,
      },
      "policy" => {
        "policy_revision" => SecureRandom.uuid,
        "enabled" => false,
        "selection" => "all_public",
        "category_ids" => [],
        "include_topic_ids" => [],
        "exclude_topic_ids" => [],
        "include_unlisted" => false,
        "publication_kind" => "dynamic",
        "presentation_mode" => "simple",
        "author_ids" => [],
        "taxonomy_ids" => [],
        "existing_record_adoption" => "disabled",
        "adoptable_resource_ids" => [],
      },
    }
    @connection.update!(cms_configuration: @configuration)
    @store =
      described_class.new(
        @connection,
        clock: -> { @now },
        authenticated_secret_digest: @connection.secret_digest,
      )
  end

  def rejected(code, &block)
    expect(&block).to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq(code)
    }
  end

  def entry(id, label: "Native #{id}", available: true)
    { "id" => id.to_s, "label" => label, "available" => available }
  end

  def start(total, kind: "authors", native_revision: "native-catalog-r1")
    @store
      .begin_upload(
        "mutation_id" => SecureRandom.uuid,
        "kind" => kind,
        "native_revision" => native_revision,
        "total_items" => total,
      )
      .body
      .fetch("upload_id")
  end

  def append(upload, number, items, mutation: SecureRandom.uuid)
    @store.append_page(upload, "mutation_id" => mutation, "page" => number, "items" => items)
  end

  def finish(upload, total, mutation: SecureRandom.uuid)
    @store.finalize(
      upload,
      "mutation_id" => mutation,
      "upload_id" => upload,
      "expected_total_items" => total,
    )
  end

  def accept(items, kind: "authors", native_revision: "native-catalog-r1", page_size: 100)
    upload = start(items.size, kind: kind, native_revision: native_revision)
    items.each_slice(page_size).with_index { |slice, number| append(upload, number, slice) }
    [upload, finish(upload, items.size)]
  end

  def delivery_counts
    [
      DiscussionBridgeCmsWork.count,
      DiscussionBridgeCmsMapping.count,
      DiscussionBridgeCmsSourceIntent.count,
      DiscussionBridgeCmsSourceStream.count,
      DiscussionBridgeBridgeRecord.count,
      Topic.count,
      Post.count,
    ]
  end

  it "permits catalog absence for empty selections without manufacturing a catalog" do
    rejected("resource_not_found") { @store.read("kind" => "authors") }
    availability = described_class.selected_availability(@connection, configuration: @configuration)
    expect(availability.available).to eq(true)
    expect(availability.catalog_revisions).to eq("authors" => nil, "taxonomy" => nil)
    expect(DiscussionBridgeCmsCatalogSnapshot.count).to eq(0)
    expect(DiscussionBridgeCmsCatalogCursor.count).to eq(0)
  end

  it "accepts an exact zero catalog with no pages and no publication authority" do
    counts = delivery_counts
    upload = start(0)
    result = finish(upload, 0)
    expect(result.body).to include("total_items" => 0, "items" => [], "next_cursor" => nil)
    expect(result.change.total_items).to eq(0)
    expect(@store.read("kind" => "authors").body).to eq(result.body)
    expect(@connection.reload.cms_configuration).to eq(@configuration)
    expect(DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload).pages.count).to eq(0)
    expect(delivery_counts).to eq(counts)
  end

  it "requires zero catalogs to have no pages and nonfinal pages to be nonempty" do
    zero = start(0)
    rejected("catalog_page_conflict") { append(zero, 0, []) }
    upload = start(1)
    rejected("catalog_page_conflict") { append(upload, 0, []) }
    append(upload, 0, [entry("owned")])
    # The grammar permits empty arrays; prose forbids nonfinal empty pages.
    append(upload, 1, [])
    expect(finish(upload, 1).body.fetch("items")).to eq([entry("owned")])
  end

  it "requires sequential pages, preserves accepted page receipts and rejects changed entries" do
    upload = start(2)
    rejected("catalog_page_conflict") { append(upload, 1, [entry("late")]) }
    first = append(upload, 0, [entry("one")])
    append(upload, 1, [entry("two")])
    expect(append(upload, 0, [entry("one")]).body).to eq(first.body)
    rejected("catalog_page_conflict") { append(upload, 0, [entry("one", label: "Changed")]) }
    expect(DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload).received_items).to eq(2)
    expect(finish(upload, 2).body.fetch("items").map { |item| item.fetch("id") }).to eq(%w[one two])
  end

  it "rejects duplicate IDs across all pages without collapsing labels or byte identities" do
    upload = start(3)
    rejected("catalog_page_conflict") do
      append(upload, 0, [entry("same"), entry("same", label: "Another label")])
    end
    append(upload, 0, [entry("same")])
    rejected("catalog_page_conflict") { append(upload, 1, [entry("same")]) }
    append(upload, 1, [entry(" same "), entry("SAME")])
    expect(finish(upload, 3).body.fetch("items").map { |item| item.fetch("id") }).to eq(
      ["same", " same ", "SAME"],
    )
  end

  it "keeps author and taxonomy identities in their declared kind namespaces" do
    accept([entry("17", label: "Native author")])
    accept([entry("17", label: "Native taxonomy")], kind: "taxonomy")
    expect(@store.read("kind" => "authors").body.dig("items", 0, "label")).to eq("Native author")
    expect(@store.read("kind" => "taxonomy").body.dig("items", 0, "label")).to eq("Native taxonomy")
  end

  it "preserves the accepted snapshot when total, order or completion is wrong" do
    _, old = accept([entry("prior")])
    upload = start(2)
    rejected("catalog_page_conflict") { append(upload, 0, [entry("a"), entry("b"), entry("c")]) }
    append(upload, 0, [entry("a")])
    rejected("catalog_page_conflict") { finish(upload, 1) }
    rejected("catalog_page_conflict") { finish(upload, 2) }
    expect(@store.read("kind" => "authors").body).to eq(old.body)
    expect(DiscussionBridgeCmsCatalogSnapshot.where(active: true).count).to eq(1)
  end

  it "rolls back a failed output projection before replacing the prior accepted catalog" do
    _, old = accept([entry("prior")])
    upload = start(1)
    append(upload, 0, [entry("new")])
    row = DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload).entries.first
    row.update_columns(payload: entry("new", label: "x" * 201))
    rejected("metadata_unavailable") { finish(upload, 1) }
    expect(@store.read("kind" => "authors").body).to eq(old.body)
    expect(DiscussionBridgeCmsCatalogSnapshot.where(active: true).count).to eq(1)
    expect(DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload).state).to eq("open")
  end

  it "returns exact encrypted mutation receipts without reappending or reactivating an old catalog" do
    upload = start(1)
    page_mutation = SecureRandom.uuid
    page = append(upload, 0, [entry("first")], mutation: page_mutation)
    final_mutation = SecureRandom.uuid
    first = finish(upload, 1, mutation: final_mutation)
    _, current = accept([entry("current")], native_revision: "native-catalog-r2")
    expect(append(upload, 0, [entry("first")], mutation: page_mutation).body).to eq(page.body)
    expect(finish(upload, 1, mutation: final_mutation).body).to eq(first.body)
    repeated = finish(upload, 1)
    expect(repeated.body).to eq(first.body)
    expect(repeated.change).to be_nil
    expect(@store.read("kind" => "authors").body).to eq(current.body)
    receipt =
      DiscussionBridgeCmsMutationReceipt.find_by!(route: "catalog_page", mutation_id: page_mutation)
    expect(receipt.request_tree.keys).to eq(["ciphertext"])
    rejected("mutation_conflict") do
      append(upload, 0, [entry("different")], mutation: page_mutation)
    end
    expect(DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload).entries.count).to eq(1)
  end

  it "expires new upload mutations at 24 hours while allowing the original successful stage replay" do
    upload = start(1)
    mutation = SecureRandom.uuid
    accepted = append(upload, 0, [entry("owned")], mutation: mutation)
    @now = DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload).expires_at
    rejected("catalog_upload_expired") { finish(upload, 1) }
    rejected("catalog_upload_expired") { append(upload, 0, [entry("owned")]) }
    expect(append(upload, 0, [entry("owned")], mutation: mutation).body).to eq(accepted.body)
    expect(DiscussionBridgeCmsCatalogSnapshot.count).to eq(0)
  end

  it "pins deterministic pages to one accepted snapshot across a native refresh" do
    items = 101.times.map { |index| entry("original-#{index}") }
    _, first = accept(items)
    token = first.body.fetch("next_cursor")
    expect(first.body.fetch("items").size).to eq(100)
    accept([entry("new")], native_revision: "native-catalog-r2")
    last = @store.read("kind" => "authors", "cursor" => token).body
    expect(last.fetch("catalog_revision")).to eq(first.body.fetch("catalog_revision"))
    expect(last.fetch("items")).to eq([items.last])
    expect(last.fetch("next_cursor")).to be_nil
    expect(@store.read("kind" => "authors", "cursor" => token).body).to eq(last)
    expect(@store.read("kind" => "authors").body.fetch("native_revision")).to eq(
      "native-catalog-r2",
    )
  end

  it "bounds encoded pages and preserves exact Unicode and JSON-escaped metadata" do
    items = 101.times.map { |index| entry("#{index}#{'"' * 249}", label: "é" * 100) }
    _, first = accept(items, page_size: 50)
    expect(first.body.fetch("items").size).to eq(100)
    second = @store.read("kind" => "authors", "cursor" => first.body.fetch("next_cursor")).body
    expect(first.body.fetch("items") + second.fetch("items")).to eq(items)
    expect(JSON.generate(first.body).bytesize).to be <= 262_144
    expect(JSON.generate(second).bytesize).to be <= 262_144
    expect(first.body.to_s.include?(@secret)).to eq(false)
  end

  it "rejects page count and nonblank identity violations before storing entries" do
    upload = start(101)
    rejected("invalid_field") { append(upload, 0, 101.times.map { |index| entry(index) }) }
    rejected("invalid_field") { append(upload, 0, [entry(" ")]) }
    expect(DiscussionBridgeCmsCatalogEntry.count).to eq(0)
  end

  it "retains original cursor expiry through continuation and rejects lost snapshot entries" do
    _, first = accept(201.times.map { |index| entry(index) })
    token = first.body.fetch("next_cursor")
    @now += 3600
    middle = @store.read("kind" => "authors", "cursor" => token).body
    next_token = middle.fetch("next_cursor")
    first_cursor =
      DiscussionBridgeCmsCatalogCursor.find_by!(token_digest: Digest::SHA256.hexdigest(token))
    second_cursor =
      DiscussionBridgeCmsCatalogCursor.find_by!(token_digest: Digest::SHA256.hexdigest(next_token))
    expect(second_cursor.expires_at).to eq(first_cursor.expires_at)
    second_cursor.catalog_snapshot.entries.where(ordinal: 200).delete_all
    rejected("cursor_expired") { @store.read("kind" => "authors", "cursor" => next_token) }
    @now = first_cursor.expires_at
    rejected("cursor_expired") { @store.read("kind" => "authors", "cursor" => token) }
  end

  it "rechecks kind, current direction scope, ownership and immediate credential rotation" do
    upload, first = accept(101.times.map { |index| entry(index) })
    token = first.body.fetch("next_cursor")
    rejected("cursor_scope_changed") { @store.read("kind" => "taxonomy", "cursor" => token) }
    other, =
      DiscussionBridgeContentConnection.issue!(
        name: "Other catalog",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    other.update!(cms_configuration: @configuration.deep_dup)
    other_store = described_class.new(other, clock: -> { @now })
    rejected("resource_not_found") do
      other_store.append_page(
        upload,
        "mutation_id" => SecureRandom.uuid,
        "page" => 0,
        "items" => [],
      )
    end
    rejected("cursor_scope_changed") { other_store.read("kind" => "authors", "cursor" => token) }
    @connection.update!(allowed_directions: %w[from_discourse to_discourse])
    rejected("cursor_scope_changed") { @store.read("kind" => "authors", "cursor" => token) }
    @connection.rotate_secret!
    rejected("authentication_failed") { @store.read("kind" => "authors") }
  end

  it "invalidates open uploads and old read cursors across scope ABA without deleting accepted metadata" do
    _, first = accept(101.times.map { |index| entry(index) })
    upload = start(1)
    described_class.invalidate_scope!(@connection, clock: -> { @now })
    @connection.update!(enabled: false)
    rejected("connection_disabled") { @store.read("kind" => "authors") }
    @connection.update!(enabled: true)
    # Durable invalidation must survive restoration and an earlier wall clock.
    @now -= 60
    rejected("catalog_upload_expired") { append(upload, 0, [entry("new")]) }
    rejected("cursor_expired") do
      @store.read("kind" => "authors", "cursor" => first.body.fetch("next_cursor"))
    end
    expect(@store.read("kind" => "authors").body.fetch("total_items")).to eq(101)
  end

  it "rolls scope invalidation back with its owning connection mutation" do
    upload, first = accept(101.times.map { |index| entry(index) })
    token = first.body.fetch("next_cursor")
    DiscussionBridgeContentConnection.transaction do
      @connection.lock!
      described_class.invalidate_scope!(@connection, clock: -> { @now })
      @connection.update!(enabled: false)
      raise ActiveRecord::Rollback
    end
    expect(@connection.reload.enabled).to eq(true)
    expect(DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload).invalidated_at).to be_nil
    expect(@store.read("kind" => "authors", "cursor" => token).body.fetch("items").size).to eq(1)
  end

  it "reports selected disappearance and unavailability without changing policy or creating work" do
    accept([entry("present"), entry("unavailable", available: false)])
    configuration = @configuration.deep_dup
    configuration.fetch("policy")["author_ids"] = %w[present unavailable missing]
    configuration.fetch("policy")["taxonomy_ids"] = ["no-taxonomy-catalog"]
    counts = delivery_counts
    availability = described_class.selected_availability(@connection, configuration: configuration)
    expect(availability.available).to eq(false)
    expect(availability.missing_ids).to eq(
      "authors" => ["missing"],
      "taxonomy" => ["no-taxonomy-catalog"],
    )
    expect(availability.unavailable_ids).to eq("authors" => ["unavailable"], "taxonomy" => [])
    @connection.update!(cms_configuration: configuration)
    result = accept([entry("replacement")], native_revision: "native-catalog-r2").last
    expect(result.change.selected_availability.missing_ids.fetch("authors")).to eq(
      %w[present unavailable missing],
    )
    expect(@connection.reload.cms_configuration).to eq(configuration)
    expect(delivery_counts).to eq(counts)
  end

  it "accepts descriptive catalogs with To-only direction and publication off" do
    @connection.update!(allowed_directions: ["to_discourse"])
    counts = delivery_counts
    _, result = accept([entry("native-author")])
    expect(result.body.fetch("items")).to eq([entry("native-author")])
    expect(@connection.reload.cms_configuration.dig("policy", "enabled")).to eq(false)
    expect(delivery_counts).to eq(counts)
  end

  it "reports damaged selected catalog data without blocking a different catalog repair" do
    accept([entry("author")])
    accept([entry("term")], kind: "taxonomy")
    configuration = @configuration.deep_dup
    configuration.fetch("policy")["author_ids"] = ["author"]
    configuration.fetch("policy")["taxonomy_ids"] = ["term"]
    @connection.update!(cms_configuration: configuration)
    snapshot = DiscussionBridgeCmsCatalogSnapshot.find_by!(kind: "taxonomy", active: true)
    DiscussionBridgeCmsCatalogEntry.where(catalog_upload_id: snapshot.catalog_upload_id).delete_all
    result = accept([entry("author")], native_revision: "native-catalog-r2").last
    expect(result.change.selected_availability.available).to eq(false)
    expect(result.change.selected_availability.catalog_errors).to eq(
      "taxonomy" => "metadata_unavailable",
    )
    expect(result.change.selected_availability.missing_ids.fetch("taxonomy")).to eq([])
    expect(@store.read("kind" => "authors").body.fetch("native_revision")).to eq(
      "native-catalog-r2",
    )
  end

  it "stops counter exhaustion instead of wrapping or allocating unsafe pages" do
    upload = start(1)
    append(upload, 0, [entry("owned")])
    row = DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload)
    row.update_columns(next_page: DiscussionBridge::CmsProtocol::MAX_COUNTER)
    rejected("storage_exhausted") { append(upload, DiscussionBridge::CmsProtocol::MAX_COUNTER, []) }
    expect(row.reload.next_page).to eq(DiscussionBridge::CmsProtocol::MAX_COUNTER)
    expect(row.entries.count).to eq(1)
  end

  it "does not write new catalog state in native read-only mode or make a duplicate success replay" do
    input = {
      "mutation_id" => SecureRandom.uuid,
      "kind" => "authors",
      "native_revision" => "native-r1",
      "total_items" => 0,
    }
    accepted = @store.begin_upload(input)
    allow(Discourse).to receive(:readonly_mode?).and_return(true)
    expect(@store.begin_upload(input).body).to eq(accepted.body)
    rejected("native_service_unavailable") do
      @store.begin_upload(input.merge("mutation_id" => SecureRandom.uuid))
    end
    expect(DiscussionBridgeCmsCatalogUpload.count).to eq(1)
  end
end
