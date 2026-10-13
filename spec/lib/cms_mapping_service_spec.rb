# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsMappingService do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @now = Time.current
    @connection, @secret = connection("CMS mapping native author fixture")
    @store = described_class.new(@connection, clock: -> { @now })
  end

  def connection(name)
    value, secret =
      DiscussionBridgeContentConnection.issue!(
        name: name,
        platform: "hugo",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    value.update!(
      cms_configuration: {
        "profile" => "hugo",
        "destination_origin" => "https://site.example",
        "publication_lane" => "news",
        "native_capabilities" => {
          "native_revision" => "native:fixture",
          "supported_presentations" => %w[simple full],
          "publication_kind" => "static",
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
          "publication_kind" => "static",
          "presentation_mode" => "simple",
          "author_ids" => [],
          "taxonomy_ids" => [],
          "existing_record_adoption" => "disabled",
          "adoptable_resource_ids" => [],
        },
      },
    )
    [value, secret]
  end

  def receive!(value = @connection)
    receiver = DiscussionBridge::CmsSourceStore.new(value, clock: -> { @now })
    receiver.refresh_topic!(topic.id)
    intent = receiver.intent("topic:#{topic.id}")
    intent
      .source_revisions
      .find_by!(source_revision: intent.current_source_revision)
      .source_metadata
  end

  def prepare_input(metadata, value: @connection, **changes)
    {
      "mutation_id" => SecureRandom.uuid,
      "source_id" => metadata.fetch("source_id"),
      "source_revision" => metadata.fetch("source_revision"),
      "policy_revision" => value.cms_configuration.fetch("policy").fetch("policy_revision"),
      "external_id" => "native-page:exact-record",
      "canonical_url" => "https://site.example/article/",
    }.merge(changes.stringify_keys)
  end

  def rejected(code, &block)
    expect(&block).to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq(code)
    }
  end

  def mutation_counts
    [
      DiscussionBridgeBridgeRecord.count,
      DiscussionBridgeContentBinding.count,
      DiscussionBridgeCmsMapping.count,
      DiscussionBridgeCmsWork.count,
      DiscussionBridgeCmsUrlReservation.count,
      DiscussionBridgeCmsMutationReceipt.count,
    ]
  end

  def baseline(
    value = @connection,
    external_id: "baseline-native-page",
    canonical_url: "https://site.example/article/"
  )
    DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: value.id,
      topic_id: topic.id,
      external_id: external_id,
      canonical_url: canonical_url,
      lane: "news",
      native_materialization: false,
      presentation_mode: "full",
    ).record
  end

  def allow_adoption!(record)
    configuration = @connection.cms_configuration.deep_dup
    configuration.fetch("policy").merge!(
      "existing_record_adoption" => "explicit_records_only",
      "adoptable_resource_ids" => [record.resource_id],
    )
    @connection.update!(cms_configuration: configuration)
  end

  def adopt_input(record, source_revision: nil, native_id: "native:baseline-page", **changes)
    binding = record.active_binding("presentation")
    {
      "mutation_id" => SecureRandom.uuid,
      "resource_id" => record.resource_id,
      "source_id" => "topic:#{topic.id}",
      "expected_topic_id" => topic.id.to_s,
      "ownership" => {
        "resource_id" => record.resource_id,
        "external_id" => binding.external_id,
        "native_id" => native_id,
        "canonical_url" => binding.canonical_url,
        "source_revision" => source_revision,
        "ownership_receipt_sha256" => "a" * 64,
      },
    }.merge(changes.stringify_keys)
  end

  it "cannot discover or create a publication intent, record or work from prepare" do
    input =
      prepare_input({ "source_id" => "topic:#{topic.id}", "source_revision" => "unknown-revision" })
    rejected("native_service_unavailable") { @store.prepare(input) }
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsSourceStream.count).to eq(0)
    expect(mutation_counts).to eq([0, 0, 0, 0, 0, 0])
    receive!
    rejected("source_ineligible") { @store.prepare(input.merge("source_id" => "unknown-source")) }
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(1)
    expect(mutation_counts).to eq([0, 0, 0, 0, 0, 0])
  end

  it "prepares one authorized pending mapping/work and reserves identity without native object or proof creation" do
    metadata = receive!
    native_before = [Topic.count, Post.count, topic.attributes, first_post.attributes]
    response = @store.prepare(prepare_input(metadata))
    expect(response.status).to eq(201)
    DiscussionBridge::CmsProtocol.validate!("Mapping", response.body)
    mapping = DiscussionBridgeCmsMapping.first
    binding = mapping.content_binding
    expect(response.body.fetch("mapping_state")).to eq("pending")
    expect(response.body.fetch("desired_source_revision")).to eq(metadata.fetch("source_revision"))
    %w[
      destination_native_id
      synchronized_source_revision
      publicly_verified_source_revision
      synchronized_at
      publicly_verified_at
    ].each { |field| expect(response.body.fetch(field)).to eq(nil) }
    expect(mapping.native_result).to eq(nil)
    expect(mapping.verified_result).to eq(nil)
    expect(binding.native_materialization).to eq(true)
    expect(binding.cms_protocol_version).to eq(2)
    expect(mapping.work_items.first.source_snapshot).to eq(metadata)
    expect(mapping.work_items.first.attempt).to eq(0)
    expect(mapping.fence_generation).to eq(0)
    expect(mutation_counts).to eq([1, 1, 1, 1, 1, 1])
    expect([Topic.count, Post.count, topic.reload.attributes, first_post.reload.attributes]).to eq(
      native_before,
    )
    receipt = DiscussionBridgeCmsMutationReceipt.first
    expect(receipt.request_tree.keys).to eq(["ciphertext"])
    expect(receipt.response_body.keys).to eq(["ciphertext"])
    expect(JSON.generate(receipt.request_tree)).not_to include(
      binding.external_id,
      binding.canonical_url,
      @secret,
    )
  end

  it "preserves exact opaque whitespace and escaped URL/query bytes without legacy normalization" do
    metadata = receive!
    url = "https://SITE.EXAMPLE:443/%41?x=%2f&x=%2F"
    input = prepare_input(metadata, external_id: " padded/é?exact ", canonical_url: url)
    first = @store.prepare(input)
    expect(first.body.fetch("external_id")).to eq(input.fetch("external_id"))
    expect(first.body.fetch("canonical_url")).to eq(url)
    expect(DiscussionBridgeCmsUrlReservation.first.canonical_url).to eq(url)
    expect(DiscussionBridgeCmsUrlReservation.first.collision_key_sha256).to eq(
      Digest::SHA256.hexdigest("https://site.example/%41?x=%2f&x=%2F"),
    )
    expect(@store.prepare(input.to_a.reverse.to_h)).to eq(first)
    expect(mutation_counts).to eq([1, 1, 1, 1, 1, 1])
  end

  it "rejects whitespace-only IDs and preserves exact untrimmed nonblank v2 identity bytes" do
    input = prepare_input(receive!, external_id: " ")
    rejected("invalid_field") { @store.prepare(input) }
    expect(mutation_counts).to eq([0, 0, 0, 0, 0, 0])
    input["external_id"] = " untrimmed opaque identity "
    first = @store.prepare(input)
    expect(first.body.fetch("external_id").bytes).to eq(input.fetch("external_id").bytes)
    expect(DiscussionBridgeContentBinding.first.external_id.bytes).to eq(
      input.fetch("external_id").bytes,
    )
    expect(@store.prepare(input).body.fetch("external_id").bytes).to eq(
      input.fetch("external_id").bytes,
    )
    expect(@store.show(first.body.fetch("mapping_id")).body.fetch("external_id").bytes).to eq(
      input.fetch("external_id").bytes,
    )
    expect(mutation_counts).to eq([1, 1, 1, 1, 1, 1])
  end

  it "replays accepted result exactly while a new matching mutation returns current mapping without new work" do
    input = prepare_input(receive!)
    first = @store.prepare(input)
    mapping = DiscussionBridgeCmsMapping.first
    mapping.update!(mapping_state: "attention")
    expect(@store.prepare(input)).to eq(first)
    current = @store.prepare(input.merge("mutation_id" => SecureRandom.uuid))
    expect(current.status).to eq(200)
    expect(current.body.fetch("mapping_state")).to eq("attention")
    expect(current.body.fetch("mapping_id")).to eq(first.body.fetch("mapping_id"))
    expect(mutation_counts).to eq([1, 1, 1, 1, 1, 2])
    rejected("mutation_conflict") do
      @store.prepare(input.merge("external_id" => "changed-identity"))
    end
    rejected("mapping_conflict") do
      @store.prepare(
        input.merge(
          "mutation_id" => SecureRandom.uuid,
          "canonical_url" => "https://site.example/changed/",
        ),
      )
    end
    expect(mutation_counts).to eq([1, 1, 1, 1, 1, 2])
  end

  it "rejects stale source/policy and current native observer lag without refreshing receiver intent" do
    metadata = receive!
    input = prepare_input(metadata)
    rejected("policy_changed") { @store.prepare(input.merge("policy_revision" => "stale-policy")) }
    rejected("revision_conflict") do
      @store.prepare(input.merge("source_revision" => "stale-source"))
    end
    first_post.update_columns(
      raw: "A native edit not yet observed",
      cooked: "<p>A native edit not yet observed</p>",
    )
    rejected("revision_conflict") { @store.prepare(input) }
    expect(DiscussionBridgeCmsSourceIntent.first.current_source_revision).to eq(
      metadata.fetch("source_revision"),
    )
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(1)
    expect(mutation_counts).to eq([0, 0, 0, 0, 0, 0])
    expect(first_post.reload.raw).to eq("A native edit not yet observed")
  end

  it "denies private/revoked source, disabled policy, unavailable selection and rotated credentials" do
    input = prepare_input(receive!)
    original_category_id = topic.category_id
    topic.update_columns(archetype: Archetype.private_message, category_id: nil)
    rejected("source_ineligible") { @store.prepare(input) }
    topic.update_columns(archetype: Archetype.default, category_id: original_category_id)
    intent = DiscussionBridgeCmsSourceIntent.first
    intent.update!(state: "revoked")
    rejected("source_ineligible") { @store.prepare(input) }
    intent.update!(state: "active")
    configuration = @connection.cms_configuration.deep_dup
    configuration.fetch("policy")["enabled"] = false
    @connection.update!(cms_configuration: configuration)
    rejected("scope_denied") { @store.prepare(input) }
    configuration.fetch("policy").merge!("enabled" => true, "author_ids" => ["missing-author"])
    @connection.update!(cms_configuration: configuration)
    rejected("catalog_entry_unavailable") { @store.prepare(input) }
    reader =
      described_class.new(@connection, authenticated_secret_digest: @connection.secret_digest)
    @connection.rotate_secret!
    rejected("authentication_failed") { reader.prepare(input) }
    expect(mutation_counts).to eq([0, 0, 0, 0, 0, 0])
  end

  it "requires explicit adoption for an existing baseline binding even when the requested identity matches" do
    record = baseline
    metadata = receive!
    before = [record.attributes, record.active_binding("presentation").attributes]
    rejected("mapping_conflict") do
      @store.prepare(prepare_input(metadata, external_id: "baseline-native-page"))
    end
    expect([record.reload.attributes, record.active_binding("presentation").attributes]).to eq(
      before,
    )
    expect(mutation_counts).to eq([1, 1, 0, 0, 0, 0])
  end

  it "blocks new mapping authority on exhausted receiver capacity while preserving accepted replay and historical reads" do
    input = prepare_input(receive!)
    accepted = @store.prepare(input)
    stream = DiscussionBridgeCmsSourceStream.first
    stream.update!(lifecycle_error_code: "storage_exhausted")
    before = mutation_counts
    expect(@store.prepare(input)).to eq(accepted)
    expect(@store.show(accepted.body.fetch("mapping_id")).status).to eq(200)
    rejected("storage_exhausted") do
      @store.prepare(input.merge("mutation_id" => SecureRandom.uuid))
    end
    expect(mutation_counts).to eq(before)
    expect(stream.reload.lifecycle_error_code).to eq("storage_exhausted")
  end

  [nil, "post:baseline:version:older"].each do |reported_revision|
    it "adopts baseline reported revision #{reported_revision.inspect} as unverified provenance without changing baseline bytes" do
      record = baseline
      allow_adoption!(record)
      metadata = receive!
      binding = record.active_binding("presentation")
      before = [record.attributes, binding.attributes, topic.attributes, first_post.attributes]
      input = adopt_input(record, source_revision: reported_revision)
      response = @store.adopt(input)
      expect(response.status).to eq(201)
      mapping = DiscussionBridgeCmsMapping.first
      expect(mapping.adoption_ownership).to eq(input.fetch("ownership"))
      expect(mapping.destination_native_id).to eq(input.fetch("ownership").fetch("native_id"))
      expect(mapping.desired_source_revision).to eq(metadata.fetch("source_revision"))
      expect(mapping.synchronized_source_revision).to eq(nil)
      expect(mapping.publicly_verified_source_revision).to eq(nil)
      expect(mapping.native_result).to eq(nil)
      expect(mapping.verified_result).to eq(nil)
      expect(mapping.mapping_state).to eq("pending")
      expect(response.body.fetch("presentation_mode")).to eq("simple")
      expect(binding.reload.native_materialization).to eq(false)
      expect(binding.cms_protocol_version).to eq(1)
      expect(binding.presentation_mode).to eq("full")
      expect(
        [
          record.reload.attributes,
          binding.reload.attributes,
          topic.reload.attributes,
          first_post.reload.attributes,
        ],
      ).to eq(before)
      expect(mutation_counts).to eq([1, 1, 1, 1, 1, 1])
      expect(@store.adopt(input)).to eq(response)
      current = @store.adopt(input.merge("mutation_id" => SecureRandom.uuid))
      expect(current.status).to eq(200)
      expect(current.body.fetch("mapping_id")).to eq(response.body.fetch("mapping_id"))
      expect(mutation_counts).to eq([1, 1, 1, 1, 1, 2])
    end
  end

  it "refuses default/missing adoption allowlist and exact resource/topic/external/URL/native mismatches" do
    record = baseline
    receive!
    input = adopt_input(record)
    rejected("scope_denied") { @store.adopt(input) }
    allow_adoption!(record)
    rejected("identity_conflict") do
      @store.adopt(input.merge("expected_topic_id" => (topic.id + 1).to_s))
    end
    rejected("identity_conflict") { @store.adopt(input.merge("resource_id" => SecureRandom.uuid)) }
    %w[external_id canonical_url].each do |field|
      changed = input.deep_dup
      changed.fetch("ownership")[field] = (
        if field == "canonical_url"
          "https://site.example/other/"
        else
          "other-external"
        end
      )
      rejected("native_ownership_conflict") { @store.adopt(changed) }
    end
    accepted = @store.adopt(input)
    changed = input.deep_dup
    changed["mutation_id"] = SecureRandom.uuid
    changed.fetch("ownership")["native_id"] = "unrelated-native-object"
    rejected("native_ownership_conflict") { @store.adopt(changed) }
    expect(DiscussionBridgeCmsMapping.first.destination_native_id).to eq(
      accepted.body.fetch("destination_native_id"),
    )
    expect(mutation_counts).to eq([1, 1, 1, 1, 1, 1])
  end

  it "matches initialized current receiver native receipt/revision while retaining the first baseline report" do
    record = baseline
    allow_adoption!(record)
    metadata = receive!
    input = adopt_input(record)
    @store.adopt(input)
    mapping = DiscussionBridgeCmsMapping.first
    original = mapping.adoption_ownership.deep_dup
    mapping.update!(
      synchronized_source_revision: metadata.fetch("source_revision"),
      native_result: {
        "kind" => "publish_revision",
        "native_id" => mapping.destination_native_id,
        "external_id" => input.fetch("ownership").fetch("external_id"),
        "canonical_url" => input.fetch("ownership").fetch("canonical_url"),
        "native_revision" => "native:current",
        "ownership_receipt_sha256" => "b" * 64,
        "representation" => {
          "kind" => "full",
          "source_content_sha256" => metadata.fetch("content_sha256"),
        },
      },
    )
    rejected("native_ownership_conflict") do
      @store.adopt(input.merge("mutation_id" => SecureRandom.uuid))
    end
    current = input.deep_dup
    current["mutation_id"] = SecureRandom.uuid
    current.fetch("ownership").merge!(
      "source_revision" => metadata.fetch("source_revision"),
      "ownership_receipt_sha256" => "b" * 64,
    )
    expect(@store.adopt(current).status).to eq(200)
    expect(mapping.reload.adoption_ownership).to eq(original)
    expect(mapping.publicly_verified_source_revision).to eq(nil)
    expect(DiscussionBridgeCmsWork.count).to eq(1)
  end

  it "isolates independent destinations and hides cross-owner mapping IDs" do
    first = @store.prepare(prepare_input(receive!))
    other, = connection("Independent CMS destination")
    second_store = described_class.new(other, clock: -> { @now })
    second =
      second_store.prepare(
        prepare_input(receive!(other), value: other, canonical_url: "https://site.example/second/"),
      )
    expect(second.body.fetch("resource_id")).not_to eq(first.body.fetch("resource_id"))
    expect(second.body.fetch("mapping_id")).not_to eq(first.body.fetch("mapping_id"))
    expect(second.body.fetch("source_id")).to eq(first.body.fetch("source_id"))
    rejected("resource_not_found") { second_store.show(first.body.fetch("mapping_id")) }
    expect(mutation_counts).to eq([2, 2, 2, 2, 2, 2])
  end

  it "rolls back new identity, reservation and pending work when encrypted receipt persistence fails" do
    input = prepare_input(receive!)
    allow(DiscussionBridgeCmsMutationReceipt).to receive(:create!).and_raise(
      StandardError,
      "injected private receipt failure",
    )
    expect { @store.prepare(input) }.to raise_error(
      StandardError,
      "injected private receipt failure",
    )
    expect(mutation_counts).to eq([0, 0, 0, 0, 0, 0])
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(1)
    expect(DiscussionBridgeCmsSourceRevision.count).to eq(1)
  end

  it "reads retained mapping off/private without source-body or lifecycle side effects and counts actual ancestry" do
    response = @store.prepare(prepare_input(receive!))
    mapping = DiscussionBridgeCmsMapping.first
    2.times do
      DiscussionBridgeCmsUrlHistoryEntry.create!(
        cms_mapping: mapping,
        url: "https://site.example/old/",
        retired_at: @now,
        move_id: SecureRandom.uuid,
        created_at: @now,
      )
    end
    configuration = @connection.cms_configuration.deep_dup
    configuration.fetch("policy")["enabled"] = false
    @connection.update!(cms_configuration: configuration)
    topic.update_columns(archetype: Archetype.private_message, category_id: nil)
    before = mutation_counts
    read = @store.show(response.body.fetch("mapping_id"))
    expect(read.body.fetch("retired_url_count")).to eq(2)
    expect(DiscussionBridgeCmsUrlReservation.count).to eq(1)
    expect(read.body.keys).not_to include(
      "content_html",
      "source_authors",
      "adoption_ownership",
      "native_result",
      "verified_result",
    )
    expect(JSON.generate(read.body)).not_to include(@secret, first_post.cooked)
    expect(mutation_counts).to eq(before)
    @connection.update!(enabled: false)
    rejected("connection_disabled") { @store.show(mapping.mapping_id) }
  end
end
