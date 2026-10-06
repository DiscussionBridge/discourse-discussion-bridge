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
      destination_policies: [
        {
          "destination_policy_id" => "destination:wordpress:approved",
          "profile" => "wordpress",
          "presentation_mode" => "interactive",
          "container_mapping" => {
            "source" => "discourse:topics",
            "destination" => "wordpress:posts",
          },
          "taxonomy_mapping" => { "mode" => "source_attribution" },
          "author_mapping" => { "mode" => "source_attribution" },
          "native_limit_policy" => {
            "maximum_bytes" => 49_152,
            "overflow_behavior" => "excerpt_with_read_more",
          },
          "catalog_revision" => "catalog:wordpress:approved",
        },
      ],
      policy_revision: "policy:system:approved",
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
    expect(page).to have_content("Topic destination")
    expect(page).to have_content("forum fallback")
    expect(page).to have_content("Adapter presence")
    expect(page).to have_content("Verified")
    expect(page).to have_content("wordpress-discussion-bridge")
    expect(page).to have_content("0.2.0-alpha.20")
    expect(page).to have_content("Last seen")
    expect(page.html).not_to include(@secret)
    expect(page).to have_css(".discussion-bridge-direction-option", count: 2)
    expect(
      page.evaluate_script(
        "Array.from(document.querySelectorAll('.discussion-bridge-direction-option')).every((label) => getComputedStyle(label).display === 'flex' && getComputedStyle(label).alignItems === 'center')",
      ),
    ).to eq(true)
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
    within("form.discussion-bridge-add-connection") do
      expect(page).to have_css(".discussion-bridge-platform", text: "Ghost")
      expect(page).to have_no_select("Platform")
      fill_in("Connection name", with: "Editorial Ghost Updated")
      check("Generate topic table of contents")
      click_button("Save connection")
    end
    expect(page).to have_content("Editorial Ghost Updated", wait: 30)
    expect(created.reload.name).to eq("Editorial Ghost Updated")
    expect(created.generate_topic_toc).to eq(true)

    catalog = created.platform_catalogs.create!(
      platform_profile: "ghost",
      catalog_revision: "catalog:ghost:system",
      current: true,
    )
    {
      "containers" => [
        { "id" => "ghost:posts", "name" => "Ghost posts", "kind" => "post_type", "available" => true },
      ],
      "taxonomies" => [],
      "terms" => [],
      "authors" => [],
      "presentation_modes" => [
        { "id" => "interactive", "name" => "Interactive", "available" => true },
      ],
      "native_limits" => [
        {
          "id" => "ghost:html",
          "name" => "Ghost HTML",
          "maximum_bytes" => 49_152,
          "overflow_behavior" => "excerpt_with_read_more",
          "available" => true,
        },
      ],
    }.each do |segment_type, items|
      catalog.segments.create!(segment_type: segment_type, items: items)
    end

    visit("/admin/plugins/discourse-discussion-bridge/connections")
    within(".discussion-bridge-connection-card", text: "Editorial Ghost Updated") do
      click_button("Manage")
    end
    click_button("Publishing")
    select("ghost", from: "Destination profile")
    select("Ghost posts", from: "Destination container")
    select("Interactive", from: "Presentation mode")
    select("Ghost HTML", from: "Native content limit")
    click_button("Approve publication destination")

    expect(page).to have_content("Editorial Ghost Updated", wait: 30)
    expect(DiscussionBridge::ConnectionCapability.publication_active?(created.reload)).to be(true)
    expect(created.destination_policies.sole).to include(
      "profile" => "ghost",
      "container_mapping" => include("destination" => "ghost:posts"),
      "catalog_revision" => "catalog:ghost:system",
    )
  end

  it "preserves mapped authors, terms, and policy identity when approving a new container" do
    mapped_policy = @connection.destination_policies.sole.deep_stringify_keys
    mapped_policy["catalog_revision"] = "catalog:wordpress:mapped"
    mapped_policy["taxonomy_mapping"] = {
      "mode" => "mapped_only",
      "items" => [
        { "source" => "discourse:tag:news", "destination" => "wordpress:term:news" },
      ],
    }
    mapped_policy["author_mapping"] = {
      "mode" => "mapped_only",
      "items" => [
        { "source" => "discourse:user:admin", "destination" => "wordpress:author:editor" },
      ],
    }
    @connection.update!(destination_policies: [mapped_policy], policy_revision: "policy:mapped:1")
    catalog = @connection.platform_catalogs.create!(
      platform_profile: "wordpress",
      catalog_revision: mapped_policy.fetch("catalog_revision"),
      current: true,
    )
    {
      "containers" => [
        { "id" => "wordpress:posts", "name" => "WordPress posts", "kind" => "post_type", "available" => true },
      ],
      "taxonomies" => [],
      "terms" => [
        {
          "id" => "wordpress:term:news",
          "taxonomy_id" => "wordpress:taxonomy:category",
          "name" => "News",
          "parent_id" => nil,
          "available" => true,
        },
      ],
      "authors" => [
        { "id" => "wordpress:author:editor", "name" => "Editor", "available" => true },
      ],
      "presentation_modes" => [
        { "id" => "interactive", "name" => "Interactive", "available" => true },
      ],
      "native_limits" => [
        {
          "id" => "wordpress:html",
          "name" => "WordPress HTML",
          "maximum_bytes" => 49_152,
          "overflow_behavior" => "excerpt_with_read_more",
          "available" => true,
        },
      ],
    }.each do |segment_type, items|
      catalog.segments.create!(segment_type: segment_type, items: items)
    end

    sign_in(admin)
    visit("/admin/plugins/discourse-discussion-bridge/connections")
    within(".discussion-bridge-connection-card", text: "Main publication") do
      click_button("Manage")
    end
    click_button("Publishing")
    select("wordpress", from: "Destination profile")
    select("WordPress posts", from: "Destination container")
    select("Interactive", from: "Presentation mode")
    select("WordPress HTML", from: "Native content limit")
    click_button("Approve publication destination")

    retained = @connection.reload.destination_policies.sole.deep_stringify_keys
    expect(retained).to include(
      "destination_policy_id" => mapped_policy.fetch("destination_policy_id"),
      "taxonomy_mapping" => mapped_policy.fetch("taxonomy_mapping"),
      "author_mapping" => mapped_policy.fetch("author_mapping"),
    )
  end

  it "persists the selected publishing connection and creates a native platform record" do
    SiteSetting.discussion_bridge_publisher_enabled = true
    topic = Fabricate(:topic, user: admin, category: category, title: "From the forum")
    Fabricate(:post, topic: topic, user: admin, post_number: 1)
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/publishing')")

    expect(page).to have_css(".discussion-bridge-publishing", wait: 30)
    fill_in("Local topic ID", with: topic.id)
    select("Main publication · wordpress", from: "Publishing connection")
    fill_in("Platform content ID", with: "astro-native:from-the-forum")
    fill_in("Presentation URL", with: "https://example.com/comments/from-the-forum/")
    check("Authorize the adapter to create or update a native platform record")
    click_button("Publish through DiscussionBridge")

    expect(page).to have_content("Platform publication created", wait: 30)
    binding = DiscussionBridgeContentBinding.find_by!(external_id: "astro-native:from-the-forum")
    expect(binding.content_connection).to eq(@connection)
    expect(binding.native_materialization).to eq(true)
    expect(binding.bridge_record.topic_id).to eq(topic.id)
    allow(DiscussionBridge::PublicationRedirectVerifier).to receive(:call).and_return(308)

    within(".discussion-bridge-publishing__recent") do
      expect(page).to have_css("th", text: "Actions")
      click_button("Migrate presentation URL")
      within(".discussion-bridge-publishing__correction-row") do
        fill_in("Presentation URL", with: "https://example.com/discussionbridge/from-the-forum/")
      end
      within(".discussion-bridge-publishing__correction-row") do
        find('input[type="checkbox"]', visible: :all).check
      end
      within(".discussion-bridge-publishing__correction-row") do
        click_button("Verify and migrate URL")
      end
    end
    expect(page).to have_content("Platform presentation URL migration verified", wait: 30)
    expect(page).to have_css(".discussion-bridge-publishing__recent .discussion-bridge-publishing__notice")
    expect(page).to have_link(
      "Main publication",
      href: "https://example.com/discussionbridge/from-the-forum/",
    )
    expect(binding.reload.canonical_url).to eq("https://example.com/discussionbridge/from-the-forum/")
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
  end

  it "restores Bridge Record filters from paginated and historical URLs" do
    sign_in(admin)
    visit("/")
    filtered = "/admin/plugins/discourse-discussion-bridge/bridge-records?" \
      "query=Community&direction=to_discourse&state=healthy&" \
      "connection_id=#{@connection.id}&page=1"
    page.execute_script("window.location.assign('#{filtered}')")

    expect(page).to have_css(".discussion-bridge-operations", wait: 30)
    expect(page).to have_field("Search", with: "Community")
    expect(page).to have_select("Content direction", selected: "To Discourse")
    expect(page).to have_select("Status", selected: "Healthy")
    expect(page).to have_select("Connection", selected: "Main publication")

    paginated = filtered.sub("page=1", "page=2")
    page.execute_script("window.location.assign('#{paginated}')")
    expect(page).to have_css(".discussion-bridge-operations", wait: 30)
    expect(page).to have_field("Search", with: "Community")
    expect(page).to have_select("Content direction", selected: "To Discourse")
    expect(page).to have_select("Status", selected: "Healthy")
    expect(page).to have_select("Connection", selected: "Main publication")

    page.go_back
    expect(page).to have_current_path(/#{Regexp.escape(filtered)}\z/, url: true, wait: 30)
    expect(page).to have_field("Search", with: "Community")
    expect(page).to have_select("Content direction", selected: "To Discourse")
  end

  it "renders truthful reconciliation without hidden support controls" do
    @connection.update!(enabled: false)
    sign_in(admin)
    visit("/")
    page.execute_script("window.location.assign('/admin/plugins/discourse-discussion-bridge/reconciliation')")

    expect(page).to have_css(".discussion-bridge-reconciliation", wait: 30)
    expect(page).to have_content("Operational truth is visible here")
    expect(page).to have_link("Export report")
    expect(page).to have_no_content("Care diagnostics")
    cells = all(".discussion-bridge-reconciliation tbody tr:first-child td")
    expect(cells.length).to eq(6)
    expect(cells.map { |cell| cell["data-label"] }).to contain_exactly(
      "Severity",
      "Issue",
      "Bridge Record",
      "Connection",
      "Discussion",
      "Recommended action",
    )

    page.current_window.resize_to(600, 900)
    expect(
      page.evaluate_script(<<~JS),
        Array.from(
          document.querySelectorAll(
            ".discussion-bridge-reconciliation tbody tr:first-child td"
          )
        ).every((cell) => {
          const label = cell.getAttribute("data-label");
          const rendered = getComputedStyle(cell, "::before").content;
          return label && rendered !== "none" && rendered !== '""';
        })
      JS
    ).to eq(true)
  end

  it "renders Operator Service as a separate default-off customer-controlled boundary" do
    sign_in(admin)
    visit("/")
    page.execute_script(
      "window.location.assign('/admin/plugins/discourse-discussion-bridge/operator-service')",
    )

    expect(page).to have_css(".discussion-bridge-operator-service", wait: 30)
    expect(page).to have_content("Operator Service")
    expect(page).to have_content("pending enrollment")
    expect(page).to have_content("DiscussionBridge")
    expect(page).to have_content("Operator credentials and entitlements never grant Content Connection scope")
    expect(page).to have_unchecked_field("Enable Operator Service")
  end

  %i[active expired revoked].each do |prior_state|
    it "replaces a #{prior_state} Operator entitlement through the native form without replacing enrollment identity" do
      recovery = prepare_operator_recovery(prior_state: prior_state)
      enrollment = recovery.fetch(:enrollment)
      original_identity = enrollment.attributes.slice(
        "id",
        "forum_id",
        "provider_id",
        "operator_user_id",
      )
      prior_audit_ids = DiscussionBridgeOperatorAuditRecord.order(:id).pluck(:id)

      sign_in(admin)
      visit("/")
      page.execute_script(
        "window.location.assign('/admin/plugins/discourse-discussion-bridge/operator-service')",
      )

      expect(page).to have_css(".discussion-bridge-operator-service", wait: 30)
      expect(page).to have_content(recovery.fetch(:current).entitlement_id)
      expect(page).to have_field("Entitlement JSON")
      fill_in("Entitlement JSON", with: JSON.generate(recovery.fetch(:replacement_payload)))
      click_button("Verify and enroll entitlement")

      expect(page).to have_content("Signed entitlement verified and enrolled.", wait: 30)
      expect(page).to have_content(recovery.fetch(:replacement_payload).fetch("entitlement_id"))
      expect(enrollment.reload.attributes.slice(*original_identity.keys)).to eq(original_identity)
      expect(enrollment.current_entitlement_id).to eq(
        recovery.fetch(:replacement_payload).fetch("entitlement_id"),
      )
      expected_prior_state = prior_state == :revoked ? "revoked" : "replaced"
      expect(recovery.fetch(:current).reload.state).to eq(expected_prior_state)
      expect(DiscussionBridgeOperatorAuditRecord.where(id: prior_audit_ids).count).to eq(prior_audit_ids.length)
    end
  end

  it "does not let the native replacement form auto-enable a disabled Operator Service" do
    recovery = prepare_operator_recovery(prior_state: :active)
    enrollment = recovery.fetch(:enrollment)
    current_id = enrollment.current_entitlement_id
    enrollment.disable!

    sign_in(admin)
    visit("/")
    page.execute_script(
      "window.location.assign('/admin/plugins/discourse-discussion-bridge/operator-service')",
    )
    expect(page).to have_field("Entitlement JSON", wait: 30)
    fill_in("Entitlement JSON", with: JSON.generate(recovery.fetch(:replacement_payload)))
    click_button("Verify and enroll entitlement")

    expect(page).to have_content("operator service is disabled", wait: 30)
    expect(page).to have_no_content("Signed entitlement verified and enrolled.")
    expect(enrollment.reload).to have_attributes(enabled: false, current_entitlement_id: current_id)
    expect(DiscussionBridgeOperatorEntitlement).not_to exist(
      entitlement_id: recovery.fetch(:replacement_payload).fetch("entitlement_id"),
    )
  end

  it "keeps native Operator state unchanged when a replacement signature is invalid" do
    recovery = prepare_operator_recovery(prior_state: :active)
    enrollment = recovery.fetch(:enrollment)
    current_id = enrollment.current_entitlement_id
    replacement = recovery.fetch(:replacement_payload).merge("signature" => "A" * 86)
    audit_ids = DiscussionBridgeOperatorAuditRecord.order(:id).pluck(:id)

    sign_in(admin)
    visit("/")
    page.execute_script(
      "window.location.assign('/admin/plugins/discourse-discussion-bridge/operator-service')",
    )
    expect(page).to have_field("Entitlement JSON", wait: 30)
    fill_in("Entitlement JSON", with: JSON.generate(replacement))
    click_button("Verify and enroll entitlement")

    expect(page).to have_content("entitlement invalid signature", wait: 30)
    expect(page).to have_no_content("Signed entitlement verified and enrolled.")
    expect(enrollment.reload.current_entitlement_id).to eq(current_id)
    expect(DiscussionBridgeOperatorEntitlement).not_to exist(
      entitlement_id: replacement.fetch("entitlement_id"),
    )
    expect(DiscussionBridgeOperatorAuditRecord.where(id: audit_ids).count).to eq(audit_ids.length)
  end

  it "renders the default-off Discourse network and enables its protected identity explicitly" do
    sign_in(admin)
    visit("/")
    page.execute_script(
      "window.location.assign('/admin/plugins/discourse-discussion-bridge/network')",
    )

    expect(page).to have_css(".discussion-bridge-network", wait: 30)
    expect(page).to have_content("Protected forum identity")
    expect(page).to have_content("No network identity exists")
    expect(page).to have_content("No peers are authorized")
    click_button("Enable network")

    identity = DiscussionBridgeForumIdentity.current
    expect(page).to have_content("Discourse network enabled", wait: 30)
    expect(page).to have_content(identity.forum_id)
    expect(page).to have_content("Synchronize authorized first posts", exact: false)
    expect(identity).to be_ready
  end

  it "rotates, disables, and reauthorizes the same peer through native controls" do
    DiscussionBridgeForumIdentity.enable!(actor: admin)
    remote_forum_id = "dbf_#{"9" * 32}"
    relationship = "hub_to_spoke"
    network_connection, = DiscussionBridgeContentConnection.issue!(
      name: "Native peer recovery",
      platform: "discourse",
      allowed_origins: ["https://peer-recovery.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: [],
      default_category_id: category.id,
      destination_policies: [
        DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
          peer_forum_id: remote_forum_id,
          relationship: relationship,
        ),
      ],
      policy_revision: DiscussionBridge::DiscourseNetworkProtocol.policy_revision(
        peer_forum_id: remote_forum_id,
        relationship: relationship,
      ),
      network_enabled: true,
      network_peer_forum_id: remote_forum_id,
      network_relationship: relationship,
    )
    peer = DiscussionBridgeNetworkPeer.create!(
      content_connection: network_connection,
      name: "Recovery Peer",
      remote_forum_id: remote_forum_id,
      remote_forum_name: "Recovery Peer Forum",
      remote_origin: "https://peer-recovery.example",
      remote_connection_id: "dbc_#{"9" * 24}",
      remote_secret: "r" * 32,
      relationship: relationship,
      enabled: true,
      authorized_by: admin,
      authorized_at: Time.zone.now,
    )
    replay = DiscussionBridgeNetworkReplay.create!(
      network_peer: peer,
      origin_forum_id: remote_forum_id,
      operation_id: "dbo_#{"7" * 32}",
      immutable_operation: { "action" => "publish" },
      immutable_sha256: Digest::SHA256.hexdigest("native peer recovery replay"),
      retained_result: { "outcome" => "created" },
      correlation_id: "native-peer-recovery-replay",
      expires_at: 1.day.from_now,
    )
    original_identity = peer.attributes.slice(
      "id",
      "content_connection_id",
      "remote_forum_id",
      "remote_connection_id",
      "relationship",
    )

    sign_in(admin)
    visit("/")
    page.execute_script(
      "window.location.assign('/admin/plugins/discourse-discussion-bridge/network')",
    )
    expect(page).to have_css(".discussion-bridge-network", wait: 30)
    expect(page.html).not_to include("r" * 32)

    fill_in("New peer secret", with: "too-short")
    page.execute_script(
      "document.querySelector('input[name=\"remote_secret\"]').form.requestSubmit()",
    )
    expect(page).to have_content("invalid network peer secret", wait: 30)
    expect(page).to have_no_content("Peer secret rotated.")
    expect(peer.reload.remote_secret).to eq("r" * 32)
    click_button("OK")

    fill_in("New peer secret", with: "s" * 32)
    click_button("Rotate peer secret")
    expect(page).to have_content("Peer secret rotated.", wait: 30)
    expect(page).to have_field("New peer secret", with: "")
    expect(peer.reload.remote_secret).to eq("s" * 32)

    click_button("Disable")
    expect(page).to have_content("Peer disabled.", wait: 30)
    expect(peer.reload.enabled).to eq(false)

    fill_in("New peer secret", with: "t" * 32)
    click_button("Rotate peer secret")
    expect(page).to have_content("Peer secret rotated.", wait: 30)
    expect(page).to have_field("New peer secret", with: "")
    expect(peer.reload).to have_attributes(enabled: false, remote_secret: "t" * 32)

    click_button("Reauthorize peer")
    expect(page).to have_content("Peer reauthorized.", wait: 30)

    expect(peer.reload.attributes.slice(*original_identity.keys)).to eq(original_identity)
    expect(peer).to have_attributes(enabled: true, disabled_at: nil)
    expect(peer.remote_secret).to eq("t" * 32)
    expect(DiscussionBridgeNetworkPeer.where(content_connection_id: network_connection.id).count).to eq(1)
    expect(replay.reload.network_peer_id).to eq(peer.id)
    expect(page.html).not_to include("t" * 32)
  end

  def prepare_operator_recovery(prior_state:)
    enrollment = DiscussionBridgeOperatorEnrollment.instance
    enrollment.update!(enabled: true)
    enrollment.bind_operator_user!(admin)
    current_signing_key = OpenSSL::PKey.generate_key("ED25519")
    current_key = create_operator_key(current_signing_key, suffix: "1")
    current_payload = operator_payload(
      signing_key: current_signing_key,
      enrollment: enrollment,
      key: current_key,
      entitlement_id: "dbe_#{"1" * 32}",
    )
    current = DiscussionBridge::OperatorEntitlementVerifier.call(
      payload: current_payload,
      enrollment: enrollment,
      actor: admin,
    )
    enrollment.activate!(entitlement: current, actor: admin)

    replacement_signing_key = current_signing_key
    replacement_key = current_key
    case prior_state
    when :expired
      current.update_columns(expires_at: 2.hours.ago, grace_until: 1.hour.ago)
    when :revoked
      enrollment.revoke_trusted_key!(trusted_key_id: current_key.id, actor: admin)
      replacement_signing_key = OpenSSL::PKey.generate_key("ED25519")
      replacement_key = create_operator_key(replacement_signing_key, suffix: "2")
    end
    replacement_payload = operator_payload(
      signing_key: replacement_signing_key,
      enrollment: enrollment,
      key: replacement_key,
      entitlement_id: "dbe_#{"2" * 32}",
    )
    {
      enrollment: enrollment,
      current: current,
      replacement_payload: replacement_payload,
    }
  end

  def create_operator_key(signing_key, suffix:)
    raw = OpenSSL::ASN1.decode(signing_key.public_to_der).value.last.value
    DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: "dbi_#{suffix * 32}",
      key_id: "native-recovery-#{suffix}",
      public_key_base64url: Base64.urlsafe_encode64(raw, padding: false),
      may_issue: true,
      enrolled_by: admin,
      enrolled_at: Time.zone.now,
    )
  end

  def operator_payload(signing_key:, enrollment:, key:, entitlement_id:)
    now = Time.zone.now.change(usec: 0)
    claims = {
      "entitlement_version" => 1,
      "entitlement_id" => entitlement_id,
      "provider_id" => enrollment.provider_id,
      "provider_name" => enrollment.provider_name,
      "forum_id" => enrollment.forum_id,
      "issuer_id" => key.issuer_id,
      "issued_at" => (now - 1.minute).iso8601,
      "not_before" => (now - 1.minute).iso8601,
      "expires_at" => (now + 1.hour).iso8601,
      "grace_until" => (now + 2.hours).iso8601,
      "scopes" => ["observe_health"],
      "key_id" => key.key_id,
    }
    canonical = DiscussionBridge::OperatorCanonicalJson.generate(claims)
    signature = signing_key.sign(
      nil,
      DiscussionBridge::OperatorEntitlementVerifier::SIGNING_DOMAIN + canonical,
    )
    claims.merge("signature" => Base64.urlsafe_encode64(signature, padding: false))
  end
end
