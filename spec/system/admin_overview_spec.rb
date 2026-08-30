# frozen_string_literal: true

describe "DiscussionBridge native product administration" do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Main publication",
      platform: "wordpress",
      allowed_origins: ["https://example.com"],
      allowed_directions: %w[to_discourse from_discourse],
      allowed_lanes: [],
    )
    topic = Fabricate(:topic, user: admin, category: category, title: "Community Guide")
    Fabricate(:post, topic: topic, user: admin, post_number: 1)
    record = DiscussionBridgeBridgeRecord.create!(
      resource_id: SecureRandom.uuid,
      direction: "to_discourse",
      state: "healthy",
      title: "Community Guide",
      topic_id: topic.id,
      effective_actor_id: admin.id,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
    )
    DiscussionBridgeContentBinding.create!(
      bridge_record: record,
      content_connection: @connection,
      role: "source",
      state: "active",
      external_id: "post-482",
      canonical_url: "https://example.com/community-guide/",
      identity_digest: Digest::SHA256.hexdigest("#{@connection.public_id}\npost-482"),
      canonical_url_digest: Digest::SHA256.hexdigest("#{@connection.public_id}\nhttps://example.com/community-guide/"),
      activated_at: Time.zone.now,
    )
  end

  it "renders the agreed Overview with product metrics, health, and both functional directions" do
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/overview')")

    expect(page).to have_css(".discussion-bridge-health__hero", text: "DiscussionBridge", wait: 30)
    expect(page).to have_content("One forum, many publishing connections, continuous discussions.")
    expect(page).to have_content("Content Connections")
    expect(page).to have_content("Bridge Records")
    expect(page).to have_content("To Discourse")
    expect(page).to have_content("From Discourse")
    expect(page).to have_link("Download support bundle")
    expect(page.html).not_to include(@secret)
  end

  it "renders independent connections and offers the native add-connection workflow" do
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/connections')")

    expect(page).to have_css(".discussion-bridge-connections", wait: 30)
    expect(page).to have_content("Main publication")
    expect(page).to have_content("wordpress")
    expect(page).to have_content("Each installation has independent credentials, scope, and many Bridge Records.")
    expect(page).to have_button("Add connection")
    expect(page).to have_button("Manage")
    expect(page.html).not_to include(@secret)
  end

  it "creates and manages another platform installation through native administration" do
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/connections')")

    expect(page).to have_css(".discussion-bridge-connections", wait: 30)
    fill_in("Connection name", with: "Editorial Ghost")
    select("ghost", from: "Platform")
    fill_in("Allowed origins (one per line)", with: "https://ghost.example")
    click_button("Add connection")

    expect(page).to have_content("Copy this connection credential now", wait: 30)
    expect(page).to have_content("Editorial Ghost")
    created = DiscussionBridgeContentConnection.find_by!(name: "Editorial Ghost")
    expect(page).to have_content(created.public_id)

    within(".discussion-bridge-connection-card", text: "Editorial Ghost") do
      click_button("Manage")
    end
    expect(page).to have_content("Manage connection")
    fill_in("Connection name", with: "Editorial Ghost Updated")
    click_button("Save connection")
    expect(page).to have_content("Editorial Ghost Updated", wait: 30)
    expect(created.reload.name).to eq("Editorial Ghost Updated")
  end

  it "renders Bridge Records with unmistakable direction and stable detail" do
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/bridge-records')")

    expect(page).to have_css(".discussion-bridge-operations", wait: 30)
    expect(page).to have_content("Direction belongs to each record, not the connection.")
    expect(page).to have_css(".discussion-bridge-direction[data-direction='to_discourse']", text: "To Discourse")
    expect(page).to have_content("Community Guide")
    expect(page).to have_button("View")
  end

  it "renders truthful reconciliation without hidden support controls" do
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/reconciliation')")

    expect(page).to have_css(".discussion-bridge-reconciliation", wait: 30)
    expect(page).to have_content("Operational truth is visible here")
    expect(page).to have_link("Export report")
    expect(page).to have_no_content("Care diagnostics")
  end
end
