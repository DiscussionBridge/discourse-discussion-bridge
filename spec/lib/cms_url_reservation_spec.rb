# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsUrlReservation do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) do
    Fabricate(:post, topic: topic, user: admin, post_number: 1)
  end

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @now = Time.current
    @connection = connection("CMS URL owner")
    @other = connection("Independent CMS URL claimant")
    @first_input = input(@connection)
    @second_input = input(@other)
    @first_service =
      DiscussionBridge::CmsMappingService.new(@connection, clock: -> { @now })
    @second_service =
      DiscussionBridge::CmsMappingService.new(@other, clock: -> { @now })
  end

  def connection(name)
    value, =
      DiscussionBridgeContentConnection.issue!(
        name: name,
        platform: "hugo",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"]
      )
    value.update!(
      cms_configuration: {
        "profile" => "hugo",
        "destination_origin" => "https://site.example",
        "publication_lane" => "news",
        "native_capabilities" => {
          "native_revision" => "native:fixture",
          "supported_presentations" => ["simple"],
          "publication_kind" => "static",
          "complete_content_supported" => true
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
          "adoptable_resource_ids" => []
        }
      }
    )
    value
  end

  def input(value)
    source = DiscussionBridge::CmsSourceStore.new(value, clock: -> { @now })
    source.refresh_topic!(topic.id)
    intent = source.intent("topic:#{topic.id}")
    {
      "mutation_id" => SecureRandom.uuid,
      "source_id" => intent.source_id,
      "source_revision" => intent.current_source_revision,
      "policy_revision" =>
        value.cms_configuration.fetch("policy").fetch("policy_revision"),
      "external_id" => "native-url-owned-record",
      "canonical_url" => "https://site.example/article/"
    }
  end

  def rejected(code, &block)
    expect(&block).to raise_error(
      DiscussionBridge::CmsProtocol::Error
    ) { |error|
      expect(error.code).to eq(code)
      expect(error.message).to eq(code)
    }
  end

  it "folds only HTTPS scheme/host/default port and keeps exact escaped path/query bytes" do
    expect(described_class.collision_key("https://SITE.EXAMPLE:443")).to eq(
      "https://site.example/"
    )
    exact = "https://SITE.EXAMPLE:443/%41?x=%2f&x=%2F"
    expect(described_class.collision_key(exact)).to eq(
      "https://site.example/%41?x=%2f&x=%2F"
    )
    expect(described_class.collision_digest(exact)).not_to eq(
      described_class.collision_digest("https://site.example/A?x=%2f&x=%2F")
    )
    expect(described_class.collision_digest(exact)).not_to eq(
      described_class.collision_digest("https://site.example/%41?x=%2F&x=%2f")
    )
    %w[
      http://site.example/a/
      https://user:pass@site.example/a/
      https://site.example/a/#fragment
      https://site.example/%2e/a/
      https://site.example/%zz/a/
    ].each do |url|
      rejected("invalid_field") { described_class.collision_key(url) }
    end
  end

  %w[active prepared retired].each do |reservation_state|
    it "retains global #{reservation_state} CMS URL reservation across connections without exposing owner" do
      first = @first_service.prepare(@first_input)
      row = DiscussionBridgeCmsUrlReservation.first
      row.update!(
        state: reservation_state,
        move_id: reservation_state == "active" ? nil : SecureRandom.uuid,
        retired_at: reservation_state == "retired" ? @now : nil
      )
      input =
        @second_input.merge(
          "canonical_url" => "https://SITE.EXAMPLE:443/article/"
        )
      rejected("url_collision") { @second_service.prepare(input) }
      expect(DiscussionBridgeCmsMapping.count).to eq(1)
      expect(DiscussionBridgeBridgeRecord.count).to eq(1)
      expect(DiscussionBridgeContentBinding.count).to eq(1)
      expect(DiscussionBridgeCmsWork.count).to eq(1)
      expect(DiscussionBridgeCmsMutationReceipt.count).to eq(1)
      expect(row.reload.cms_mapping.mapping_id).to eq(
        first.body.fetch("mapping_id")
      )
      expect(row.state).to eq(reservation_state)
    end
  end

  it "retains same-owner retired URL instead of implicitly reactivating it on a second prepare" do
    @first_service.prepare(@first_input)
    row = DiscussionBridgeCmsUrlReservation.first
    row.update!(state: "retired", move_id: SecureRandom.uuid, retired_at: @now)
    rejected("url_collision") do
      @first_service.prepare(
        @first_input.merge("mutation_id" => SecureRandom.uuid)
      )
    end
    expect(row.reload.state).to eq("retired")
    expect(DiscussionBridgeCmsMapping.count).to eq(1)
    expect(DiscussionBridgeCmsWork.count).to eq(1)
    expect(DiscussionBridgeCmsMutationReceipt.count).to eq(1)
  end

  it "checks existing foreign legacy URL ownership read-only and rolls back the new CMS bookkeeping" do
    record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @other.id,
        topic_id: topic.id,
        external_id: "legacy-native-page",
        canonical_url: @first_input.fetch("canonical_url"),
        lane: "news",
        native_materialization: false
      ).record
    binding = record.active_binding("presentation")
    before = [record.attributes, binding.attributes]
    rejected("url_collision") { @first_service.prepare(@first_input) }
    expect([record.reload.attributes, binding.reload.attributes]).to eq(before)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
    expect(DiscussionBridgeContentBinding.count).to eq(1)
    expect(DiscussionBridgeCmsMapping.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
    expect(DiscussionBridgeCmsUrlReservation.count).to eq(0)
    expect(DiscussionBridgeCmsMutationReceipt.count).to eq(0)
  end

  it "guards URL-key integrity and the database global uniqueness constraint" do
    @first_service.prepare(@first_input)
    row = DiscussionBridgeCmsUrlReservation.first
    invalid = row.dup
    invalid.collision_key_sha256 = "0" * 64
    expect(invalid).not_to be_valid
    expect(invalid.errors[:collision_key_sha256]).to include(
      "does not match URL"
    )
    expect(row.dup).not_to be_valid
    expect {
      DiscussionBridgeCmsUrlReservation.transaction(requires_new: true) do
        row.dup.save!(validate: false)
      end
    }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(DiscussionBridgeCmsUrlReservation.count).to eq(1)
  end
end
