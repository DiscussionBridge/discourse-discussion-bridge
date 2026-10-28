# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsGlobalGateObserver do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    # Scheduling is isolated; native setting events, snapshot capture, mapping,
    # cancellation and same-intent admission run through the real services.
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "Native gate retention fixture", platform: "hugo",
      allowed_origins: ["https://site.example"], allowed_directions: ["from_discourse"], allowed_lanes: ["news"],
    )
    @connection.update!(cms_configuration: {
      "profile" => "hugo", "destination_origin" => "https://site.example", "publication_lane" => "news",
      "native_capabilities" => { "native_revision" => "native:fixture", "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic", "complete_content_supported" => true },
      "policy" => { "policy_revision" => SecureRandom.uuid, "enabled" => true, "selection" => "all_public",
        "category_ids" => [], "include_topic_ids" => [], "exclude_topic_ids" => [], "include_unlisted" => false,
        "publication_kind" => "dynamic", "presentation_mode" => "simple", "author_ids" => [], "taxonomy_ids" => [] },
    })
    record = DiscussionBridge::FromDiscourseRecordCreator.call(user: admin, connection_id: @connection.id,
      topic_id: topic.id, external_id: "article", canonical_url: "https://site.example/article/").record
    @mapping = DiscussionBridgeCmsMapping.find_by!(content_binding_id: record.active_binding("presentation").id)
    @work = @mapping.work_items.order(:id).last
    # Synthetic retained retry facts, not CMS/public verification evidence.
    @work.update!(state: "retry_wait", attempt: 2, last_failure_code: "native_service_unavailable",
      retry_at: 10.minutes.from_now, failure_detail: { "retained_fixture" => true })
    @prior = @work.attributes.deep_dup
  end

  DiscussionBridge::CmsGlobalGateObserver::GATES.each_key do |setting|
    it "retains the failed edition after actual #{setting} disable and restoration" do
      source_id = @mapping.source_id
      binding = @mapping.content_binding.attributes.deep_dup
      SiteSetting.public_send("#{setting}=", false)
      @work.reload
      expect(@work.state).to eq("cancelled")
      expect(@work.same_intent_hold?).to eq(true)
      %w[work_id attempt_cycle attempt last_failure_code failure_detail source_revision policy_revision source_snapshot].each do |field|
        expect(@work.attributes.fetch(field)).to eq(@prior.fetch(field))
      end
      expect(@work.lease_verifier).to be_nil
      SiteSetting.public_send("#{setting}=", true)
      DiscussionBridge::CmsSourceLifecycle.refresh(@connection.reload, topic.id)
      expect(@mapping.work_items.count).to eq(1)
      expect(@work.reload.state).to eq("cancelled")
      expect(@work.same_intent_hold?).to eq(true)
      expect(@mapping.reload.source_id).to eq(source_id)
      expect(@mapping.content_binding.reload.attributes).to eq(binding)
      expect(@mapping.mapping_state).to eq("attention")
    end
  end

  it "admits a genuinely different current native edition while retaining held history" do
    SiteSetting.discussion_bridge_enabled = false
    SiteSetting.discussion_bridge_enabled = true
    expect(first_post.revise(admin, raw: "A new native source edition with its existing discussion identity.")).to eq(true)
    DiscussionBridge::CmsSourceLifecycle.refresh(@connection.reload, topic.id)
    current = @mapping.work_items.order(:id).last
    expect(current.id).not_to eq(@work.id)
    expect(current.state).to eq("pending")
    expect(current.source_revision).not_to eq(@prior.fetch("source_revision"))
    expect(current.policy_revision).to eq(@prior.fetch("policy_revision"))
    expect(current.attempt).to eq(0)
    expect(@work.reload.state).to eq("cancelled")
    expect(@work.same_intent_hold?).to eq(true)
    expect(@work.failure_detail).to eq(@prior.fetch("failure_detail"))
    expect(@mapping.content_binding.bridge_record.topic_id).to eq(topic.id)
  end
end
