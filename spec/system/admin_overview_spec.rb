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
    @connection.update!(
      adapter_id: "wordpress-discussion-bridge",
      adapter_version: "0.2.0-alpha.20",
      last_seen_at: Time.zone.now,
    )
    DiscussionBridgeSourceAuthor.create!(
      content_connection: @connection,
      source_author_id: "wordpress:author-7",
      display_name: "Platform Author",
      profile_url: "https://example.com/authors/platform-author/",
      last_seen_at: Time.zone.now,
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
    expect(page).to have_content("Records needing attention")
    expect(page).to have_content("In-page interaction readiness")
    expect(page).to have_content("To Discourse")
    expect(page).to have_content("From Discourse")
    expect(page).to have_content("Bridge Records publish platform content into Discourse")
    expect(page).to have_content("Bridge Records present Discourse content on connected platforms")
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
    expect(page).to have_content("Each installation has independent credentials and scope, and can have many Bridge Records.")
    expect(page).to have_button("Add connection")
    expect(page).to have_button("Manage")
    expect(page).to have_content("Topic destination")
    expect(page).to have_content("forum fallback")
    expect(page).to have_content("Adapter presence")
    expect(page).to have_content("Verified")
    expect(page).to have_content("wordpress-discussion-bridge")
    expect(page).to have_content("0.2.0-alpha.20")
    expect(page).to have_content("Last seen")
    expect(page).to have_content("Embeddable Host Missing")
    expect(page.html).not_to include(@secret)
    expect(page).to have_css(".discussion-bridge-direction-option", count: 2)
    expect(page).to have_css(".discussion-bridge-direction[data-direction='to_discourse']")
    expect(page).to have_css(".discussion-bridge-direction[data-direction='from_discourse']")
    expect(
      page.evaluate_script(
        "Array.from(document.querySelectorAll('.discussion-bridge-direction-option')).every((label) => getComputedStyle(label).display === 'flex' && getComputedStyle(label).alignItems === 'center')",
      ),
    ).to eq(true)
    expect(
      page.evaluate_script(
        "Array.from(document.querySelectorAll('.discussion-bridge-add-connection input[type=checkbox]')).every((input) => input.getBoundingClientRect().width < 64 && input.getBoundingClientRect().height < 64)",
      ),
    ).to eq(true)
    expect(
      page.evaluate_script(
        "Array.from(document.querySelectorAll('.discussion-bridge-checkbox-setting')).every((label) => { const input = label.querySelector('input'); const copy = label.querySelector('span'); return getComputedStyle(label).display === 'flex' && copy.getBoundingClientRect().width > input.getBoundingClientRect().width; })",
      ),
    ).to eq(true)
    expect(page).to have_css(".discussion-bridge-add-connection__actions .btn-primary", text: "Add connection")
  end

  it "creates and manages another platform installation through native administration" do
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/connections')")

    expect(page).to have_css(".discussion-bridge-connections", wait: 30)
    fill_in("Connection name", with: "Editorial Ghost")
    select("ghost", from: "Platform")
    fill_in("Allowed origins (one per line)", with: "https://ghost.example")
    select(category.name, from: "Companion-topic category")
    click_button("Add connection")

    expect(page).to have_content("Copy this connection credential now", wait: 30)
    expect(page).to have_button("Copy ID")
    expect(page).to have_button("Copy secret")
    expect(page).to have_content("Editorial Ghost")
    created = DiscussionBridgeContentConnection.find_by!(name: "Editorial Ghost")
    expect(page).to have_content(created.public_id)
    expect(created.default_category_id).to eq(category.id)

    within(".discussion-bridge-connection-card", text: "Editorial Ghost") do
      expect(page).to have_content("Not Yet Verified")
      expect(page).to have_content("Adapter identity")
      expect(page).to have_content("Adapter version")
    end

    within(".discussion-bridge-connection-card", text: "Editorial Ghost") do
      click_button("Manage")
    end
    expect(page).to have_content("Manage connection")
    fill_in("Connection name", with: "Editorial Ghost Updated")
    check("Generate topic table of contents")
    check("Include source in published URL")
    fill_in("Source path", with: "from-the-bridge")
    expect(page).to have_content("https://ghost.example/from-the-bridge/example-page/")
    click_button("Save connection")
    expect(page).to have_content("Editorial Ghost Updated", wait: 30)
    expect(created.reload.name).to eq("Editorial Ghost Updated")
    expect(created.generate_topic_toc).to eq(true)
    expect(created.include_source_in_published_url).to eq(true)
    expect(created.publication_source_path).to eq("from-the-bridge")
  end

  it "persists the selected publishing connection and creates a native platform record" do
    SiteSetting.discussion_bridge_publisher_enabled = true
    topic = Fabricate(:topic, user: admin, category: category, title: "From the forum")
    Fabricate(:post, topic: topic, user: admin, post_number: 1)
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/publishing')")

    expect(page).to have_css(".discussion-bridge-publishing", wait: 30)
    expect(page).to have_select("Publishing connection", selected: "Select a connection")
    expect(page).to have_css(".discussion-bridge-publishing__topic-id input[max='999999999999']")
    fill_in("Local topic ID", with: topic.id)
    select("Main publication · wordpress", from: "Publishing connection")
    fill_in("Platform content ID", with: "from-the-forum")
    expect(page).to have_field("Presentation URL", with: "https://example.com/from-the-forum/")
    check("Authorize the adapter to create or update a native platform record")
    click_button("Publish through DiscussionBridge")

    expect(page).to have_content("WordPress post created", wait: 30)
    binding = DiscussionBridgeContentBinding.find_by!(external_id: "from-the-forum")
    expect(binding.content_connection).to eq(@connection)
    expect(binding.native_materialization).to eq(true)
    expect(binding.bridge_record.topic_id).to eq(topic.id)

    within(".discussion-bridge-publishing__recent") do
      expect(page).to have_content("Recent platform publications (latest 20)")
      expect(page).to have_link("Browse all Bridge Records")
      expect(page).to have_link("Topic #{topic.id} · From the forum")
      expect(page).to have_css("th", text: "Actions")
      click_button("Change publication URL")
      within(".discussion-bridge-publishing__correction-row") do
        expect(page).to have_content("Old URL:")
        expect(page).to have_content("https://example.com/from-the-forum/")
        expect(page).to have_button("Verify redirect and change URL")
        fill_in("New platform URL", with: "https://example.com/discussionbridge/from-the-forum/")
      end
    end
    expect(binding.reload.canonical_url).to eq("https://example.com/from-the-forum/")
  end

  it "offers an explicit verified cutover for older publications without native classification" do
    SiteSetting.discussion_bridge_publisher_enabled = true
    topic = Fabricate(:topic, user: admin, category: category, title: "Older publication")
    Fabricate(:post, topic: topic, user: admin, post_number: 1)
    DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: @connection.id,
      topic_id: topic.id,
      external_id: "older-post",
      canonical_url: "https://example.com/older-post/",
    )
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/publishing')")

    within(".discussion-bridge-publishing__recent") do
      expect(page).to have_button("Verify older publication and change URL", wait: 30)
      click_button("Verify older publication and change URL")
      within(".discussion-bridge-publishing__correction-row") do
        expect(page).to have_content("Platform content ID:")
        expect(page).to have_content("older-post")
        expect(page).to have_field("Type the platform content ID shown above")
        expect(page).to have_unchecked_field(
          "I verified the new page is this native platform publication and retains this Discourse topic.",
        )
        expect(page).to have_button("Verify redirect and change URL")
      end
    end
  end

  it "manages observed platform authors inside the selected connection" do
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/connections')")

    expect(page).to have_css(".discussion-bridge-connections", wait: 30)
    within(".discussion-bridge-connection-card", text: "Main publication") do
      click_button("Manage")
    end
    click_button("Authors")
    expect(page).to have_content("Platform Author")
    expect(page).to have_content("wordpress:author-7")
    select("Map platform authors", from: "Authorship mode")
    select("Hold for operator mapping", from: "Unmapped author policy")
    fill_in("Unmapped", with: admin.username)
    click_button("Save mapping")
    click_button("Save connection")

    expect(@connection.reload.authorship_mode).to eq("mapped")
    expect(@connection.unmapped_author_policy).to eq("hold")
    expect(@connection.source_authors.first.discourse_user).to eq(admin)
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
    expect(page).to have_css(".discussion-bridge-operations__search .btn-primary", text: "Apply")
    expect(page).to have_css("td .btn-primary", text: "View")
    within(".discussion-bridge-create-from") do
      expect(page).to have_select("Connection", selected: "Select a connection")
      expect(page).to have_css("input[max='999999999999']")
    end
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
