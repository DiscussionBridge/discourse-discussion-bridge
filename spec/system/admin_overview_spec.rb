# frozen_string_literal: true

describe "DiscussionBridge admin overview" do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_connection_id = "astro"
    SiteSetting.discussion_bridge_connection_secret = "never-render-this-secret"
    SiteSetting.discussion_bridge_trusted_origins = "https://example.com"
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    SiteSetting.discussion_bridge_comments_only_full_interactive = true
    SiteSetting.embed_full_app = true
    SiteSetting.embed_full_app_signin_flow = true

    DiscussionBridgeConnection.create!(
      connection_id: "astro",
      canonical_source_url: "https://example.com/complete",
      source_identity_digest: Digest::SHA256.hexdigest("astro\nhttps://example.com/complete"),
      state: "complete",
      topic_id: Fabricate(:topic, user: admin, category: category).id,
      effective_actor_id: admin.id,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
    )
    DiscussionBridgeConnection.create!(
      connection_id: "astro",
      canonical_source_url: "https://example.com/failed",
      source_identity_digest: Digest::SHA256.hexdigest("astro\nhttps://example.com/failed"),
      state: "failed",
      effective_actor_id: admin.id,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
    )
  end

  it "renders the native overview from live plugin state without rejected controls or secrets" do
    sign_in(admin)

    visit("/")
    page.execute_script(
      "window.location.assign('/admin/plugins/discourse-discussion-bridge/health')",
    )

    expect(page).to have_css(
      ".discussion-bridge-health__hero",
      text: "DiscussionBridge",
      wait: 30,
    )
    expect(page).to have_css(".discussion-bridge-health__metric", text: /Plugin status\s+Enabled/)
    expect(page).to have_css(".discussion-bridge-health__metric", text: /Companion mappings\s+2/)
    expect(page).to have_css(".discussion-bridge-health__metric", text: /Completed mappings\s+1/)
    expect(page).to have_css(".discussion-bridge-health__metric", text: /Failed mappings\s+1/)
    expect(page).to have_css(
      ".discussion-bridge-health__readiness[data-state='ready']",
      count: 2,
    )
    expect(page).to have_no_content("Bridge Records")
    expect(page).to have_no_content("Content Connections")
    expect(page).to have_no_button("Add connection")
    expect(page.html).not_to include("never-render-this-secret")
  end

  it "connects the native mappings page to persisted plugin state" do
    sign_in(admin)
    visit("/")

    page.execute_script(
      "window.location.assign('/admin/plugins/discourse-discussion-bridge/operations')",
    )
    expect(page).to have_css(
      ".discussion-bridge-operations",
      text: "Mappings and audit evidence",
      wait: 30,
    )
    expect(page).to have_css(
      ".discussion-bridge-operations__source",
      text: "https://example.com/complete",
    )
    expect(page).to have_no_content("Bridge Records")
  end

  it "connects the native reconciliation page to persisted plugin state" do
    sign_in(admin)
    visit("/")

    page.execute_script(
      "window.location.assign('/admin/plugins/discourse-discussion-bridge/reconciliation')",
    )
    expect(page).to have_css(
      ".discussion-bridge-reconciliation",
      text: "Reconciliation queue",
      wait: 30,
    )
    expect(page).to have_css(
      ".discussion-bridge-reconciliation__severity[data-severity='medium']",
      text: "medium",
    )
    expect(page).to have_content("failed mapping")
    expect(page).to have_button("Authorize retry")
    expect(page).to have_no_content("Migration")
  end
end
