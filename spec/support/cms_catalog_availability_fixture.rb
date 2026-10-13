# frozen_string_literal: true

# HELD native author fixtures. Receiver reports below are protocol fixtures;
# they do not qualify any real remote CMS ownership/public verifier.
RSpec.shared_context "CMS catalog availability native author fixture" do
  fab!(:cms_admin, :admin)
  fab!(:cms_topic) { Fabricate(:topic, user: cms_admin) }
  fab!(:cms_first_post) { Fabricate(:post, topic: cms_topic, user: cms_admin, post_number: 1) }
  let(:cms_publication_kind) { "dynamic" }
  let(:cms_author_ids) { ["writer"] }
  let(:cms_taxonomy_ids) { [] }
  let(:cms_allowed_lanes) { ["news"] }
  let(:cms_seed_authors) { true }
  let(:cms_seed_taxonomy) { cms_taxonomy_ids.any? }
  let(:cms_build_work) { true }

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @cms_now = Time.current.change(usec: 0)
    @cms_connection, @cms_secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Catalog availability native author fixture",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: cms_allowed_lanes,
      )
    @cms_configuration = {
      "profile" => "ghost",
      "destination_origin" => "https://site.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "capability-r1",
        "supported_presentations" => ["simple"],
        "publication_kind" => cms_publication_kind,
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
        "publication_kind" => cms_publication_kind,
        "presentation_mode" => "simple",
        "author_ids" => cms_author_ids,
        "taxonomy_ids" => cms_taxonomy_ids,
        "existing_record_adoption" => "disabled",
        "adoptable_resource_ids" => [],
      },
    }
    @cms_connection.update!(cms_configuration: @cms_configuration)
    @cms_store =
      DiscussionBridge::CmsCatalogStore.new(
        @cms_connection,
        clock: -> { @cms_now },
        authenticated_secret_digest: @cms_connection.secret_digest,
      )
    cms_accept([cms_entry("writer")]) if cms_seed_authors
    cms_accept(cms_taxonomy_ids.map { |id| cms_entry(id) }, kind: "taxonomy") if cms_seed_taxonomy
    if cms_build_work
      record =
        DiscussionBridge::FromDiscourseRecordCreator.call(
          user: cms_admin,
          connection_id: @cms_connection.id,
          topic_id: cms_topic.id,
          external_id: "article",
          canonical_url: "https://site.example/article/",
          lane: "news",
          native_materialization: true,
          presentation_mode: "simple",
        ).record
      @cms_mapping =
        DiscussionBridgeCmsMapping.create!(
          mapping_id: SecureRandom.uuid,
          content_connection: @cms_connection,
          content_binding: record.active_binding("presentation"),
          source_id: "topic:#{cms_topic.id}",
          mapping_revision: SecureRandom.uuid,
        )
      @cms_coordinator =
        DiscussionBridge::CmsWorkCoordinator.new(@cms_connection, clock: -> { @cms_now })
      DiscussionBridge::CmsSourceLifecycle.new(@cms_connection, clock: -> { @cms_now }).refresh(
        cms_topic.id,
      )
      @cms_work = @cms_mapping.work_items.order(created_at: :desc, id: :desc).first!
    end
  end

  def cms_entry(id, available: true)
    { "id" => id, "label" => "Native description", "available" => available }
  end

  def cms_lifecycle(permanent_failure: nil)
    DiscussionBridge::CmsCatalogAvailabilityLifecycle.new(
      @cms_connection,
      clock: -> { @cms_now },
      authenticated_secret_digest: @cms_connection.secret_digest,
      permanent_failure: permanent_failure,
    )
  end

  def cms_begin(items, kind: "authors")
    upload =
      @cms_store
        .begin_upload(
          "mutation_id" => SecureRandom.uuid,
          "kind" => kind,
          "native_revision" => SecureRandom.uuid,
          "total_items" => items.size,
        )
        .body
        .fetch("upload_id")
    items
      .each_slice(100)
      .with_index do |slice, page|
        @cms_store.append_page(
          upload,
          "mutation_id" => SecureRandom.uuid,
          "page" => page,
          "items" => slice,
        )
      end
    [
      upload,
      {
        "mutation_id" => SecureRandom.uuid,
        "upload_id" => upload,
        "expected_total_items" => items.size,
      },
    ]
  end

  def cms_accept(items, kind: "authors", lifecycle: cms_lifecycle)
    upload, input = cms_begin(items, kind: kind)
    DiscussionBridgeContentConnection.transaction(requires_new: true) do
      @cms_connection.lock!
      result = @cms_store.finalize(upload, input)
      lifecycle.apply_change!(result.change)
      result
    end
  end

  def cms_issue
    DiscussionBridge::CmsCatalogAvailabilityLifecycle.selection_issue(
      @cms_connection,
      configuration: @cms_connection.reload.cms_configuration,
    )
  end

  def cms_claim!
    lease =
      @cms_coordinator.claim(
        "mutation_id" => SecureRandom.uuid,
        "mapping_id" => @cms_mapping.mapping_id,
      ).body
    @cms_authority = {
      "work_id" => lease.fetch("work").fetch("work_id"),
      "lease_token" => lease.fetch("lease_token"),
      "lease_generation" => lease.fetch("lease_generation"),
      "source_revision" => lease.fetch("work").fetch("source_revision"),
      "policy_revision" => lease.fetch("work").fetch("policy_revision"),
    }
    lease
  end

  def cms_native_result
    {
      "kind" => "publish_revision",
      "native_id" => "native:article",
      "external_id" => "article",
      "canonical_url" => "https://site.example/article/",
      "native_revision" => "native-r1",
      "ownership_receipt_sha256" => "a" * 64,
      "representation" => {
        "kind" => "full",
        "source_content_sha256" => @cms_work.source_snapshot.fetch("content_sha256"),
      },
    }
  end

  def cms_make_live!(state)
    cms_claim!
    return if state == "leased"
    if cms_publication_kind == "static"
      @cms_transaction_id = SecureRandom.uuid
      @cms_coordinator.prepare(
        @cms_work.work_id,
        "mutation_id" => SecureRandom.uuid,
        "authority" => @cms_authority,
        "transaction_id" => @cms_transaction_id,
        "native_result" => cms_native_result,
        "prepared_at" => DiscussionBridge::CmsProtocol.instant(@cms_now),
      )
      if state == "deployed"
        @cms_coordinator.acknowledge(
          @cms_work.work_id,
          "mutation_id" => SecureRandom.uuid,
          "authority" => @cms_authority,
          "stage" => "deployed",
          "deployment_id" => "deployment-r1",
          "deployed_at" => DiscussionBridge::CmsProtocol.instant(@cms_now),
        )
      end
    else
      @cms_coordinator.acknowledge(
        @cms_work.work_id,
        "mutation_id" => SecureRandom.uuid,
        "authority" => @cms_authority,
        "stage" => "synchronized",
        "native_result" => cms_native_result,
      )
    end
    @cms_work.reload
  end

  def cms_fail!(code)
    @cms_coordinator.fail(
      @cms_work.work_id,
      "mutation_id" => SecureRandom.uuid,
      "authority" => @cms_authority,
      "code" => code,
      "native_change_applied" => false,
      "safe_detail" => nil,
      "retry_after_seconds" => nil,
    )
    @cms_work.reload
  end

  def cms_preserved_mapping_facts
    @cms_mapping.reload.attributes.except("mapping_state", "updated_at")
  end

  def cms_add_pending!(index)
    topic = Fabricate(:topic, user: cms_admin)
    Fabricate(:post, topic: topic, user: cms_admin, post_number: 1)
    record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: cms_admin,
        connection_id: @cms_connection.id,
        topic_id: topic.id,
        external_id: "article-scale-#{index}",
        canonical_url: "https://site.example/article-scale-#{index}/",
        lane: "news",
        native_materialization: true,
        presentation_mode: "simple",
      ).record
    mapping =
      DiscussionBridgeCmsMapping.create!(
        mapping_id: SecureRandom.uuid,
        content_connection: @cms_connection,
        content_binding: record.active_binding("presentation"),
        source_id: "topic:#{topic.id}",
        mapping_revision: SecureRandom.uuid,
      )
    DiscussionBridge::CmsSourceLifecycle.new(@cms_connection, clock: -> { @cms_now }).refresh(
      topic.id,
    )
    mapping.work_items.order(created_at: :desc, id: :desc).first!
  end

  def cms_rejected(code, &block)
    expect(&block).to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq(code)
    }
  end
end
