# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::HealthStatus do
  fab!(:service_actor, :admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_connection_id = "astro"
    SiteSetting.discussion_bridge_connection_secret = "never-render-this-secret"
    SiteSetting.discussion_bridge_trusted_origins = "https://example.com"
    SiteSetting.discussion_bridge_service_username = service_actor.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
  end

  it "reports a ready forum-authorized configuration without exposing the credential" do
    status = described_class.call

    expect(status.dig(:readiness, :controlled_creation_ready)).to eq(true)
    expect(status.dig(:readiness, :blockers)).to eq([])
    expect(status.dig(:connection, :credential_configured)).to eq(true)
    expect(status.dig(:operating_identity, :username)).to eq(service_actor.username)
    expect(status.dig(:forum_authority, :category_id)).to eq(category.id)
    expect(status[:lane_policies]).to eq(configured: false, count: 0, lanes: [], valid: true)
    expect(status.dig(:mappings, :total)).to eq(0)
    expect(status.dig(:readiness, :full_interactive_ready)).to eq(false)
    expect(status.dig(:readiness, :full_interactive_blockers)).to include(
      "comments_only_full_interactive_disabled",
    )
    expect(status.to_json).not_to include("never-render-this-secret")
  end

  it "reports explicit blockers for an unavailable controlled-creation configuration" do
    SiteSetting.discussion_bridge_endpoint_enabled = false
    SiteSetting.discussion_bridge_connection_secret = ""
    service_actor.update!(active: false)

    status = described_class.call

    expect(status.dig(:readiness, :controlled_creation_ready)).to eq(false)
    expect(status.dig(:readiness, :blockers)).to contain_exactly(
      "endpoint_disabled",
      "credential_missing",
      "invalid_actor",
    )
  end

  it "separately reports the Core settings required for native in-page interaction" do
    SiteSetting.discussion_bridge_comments_only_full_interactive = true
    SiteSetting.embed_full_app = false
    SiteSetting.embed_full_app_signin_flow = false

    status = described_class.call

    expect(status.dig(:readiness, :controlled_creation_ready)).to eq(true)
    expect(status.dig(:readiness, :full_interactive_ready)).to eq(false)
    expect(status.dig(:readiness, :full_interactive_blockers)).to contain_exactly(
      "embed_full_app_disabled",
      "embed_full_app_signin_flow_disabled",
    )

    SiteSetting.embed_full_app = true
    SiteSetting.embed_full_app_signin_flow = true

    expect(described_class.call.dig(:readiness, :full_interactive_ready)).to eq(true)
  end


  it "reports configured lane names without exposing their source payload" do
    SiteSetting.discussion_bridge_lane_policies = [
      { lane: "docs", category_id: category.id, tags: [], visibility: "unlisted" },
      { lane: "news", category_id: category.id, tags: [], visibility: "unlisted" },
    ].to_json

    status = described_class.call

    expect(status[:lane_policies]).to eq(configured: true, count: 2, lanes: %w[docs news], valid: true)
  end
end
