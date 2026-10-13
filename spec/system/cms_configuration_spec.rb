# frozen_string_literal: true

require "rails_helper"
require "uri"

describe "DiscussionBridge native CMS configuration UI", type: :system do
  fab!(:admin)
  fab!(:category)

  around do |example|
    previous = ApplicationController.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    example.run
  ensure
    ApplicationController.allow_forgery_protection = previous
  end

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = false # Native system Puma is isolated local HTTP.
    SiteSetting.discussion_bridge_service_username = admin.username
    SiteSetting.discussion_bridge_effective_category_id = category.id
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "CMS UI author destination",
        platform: "hugo",
        allowed_origins: ["https://cms-ui.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
  end

  def open_connections
    sign_in(admin)
    visit("/")
    page.execute_script(
      "window.location.assign('/admin/plugins/discourse-discussion-bridge/connections')",
    )
    expect(page).to have_css(".discussion-bridge-connections", wait: 30)
  end

  def open_configuration
    open_connections
    within(".discussion-bridge-connection-card", text: @connection.name) do
      click_button("CMS publication configuration")
    end
    expect(page).to have_button("Save CMS configuration", wait: 30)
  end

  def configure_form(lane: "news")
    select("Hugo", from: "Native CMS profile")
    select("https://cms-ui.example", from: "Destination HTTPS origin")
    select(lane, from: "Publication lane")
    fill_in("Actual native configuration version or revision", with: "native:ui-author-fixture-1")
    select("Static native build and deployment", from: "Native publication kind")
    check("Simple")
    select("Supported by this native configuration", from: "Complete cooked-content support")
    select("All eligible public topics", from: "Source topic selection")
    select("Simple", from: "Selected discussion presentation")
  end

  def configuration
    {
      "profile" => "hugo",
      "destination_origin" => "https://cms-ui.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "native:ui-author-fixture-1",
        "supported_presentations" => ["simple"],
        "publication_kind" => "static",
        "complete_content_supported" => true,
      },
      "policy" => {
        "enabled" => false,
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
    }
  end

  def save_configuration(value, expected: nil)
    DiscussionBridge::CmsAuthorityStore.new(@connection).configure!(
      actor: admin,
      input: {
        "expected_policy_revision" => expected,
        "configuration" => value,
      },
    )
  end

  def owned_record(connection, title:, external_id:)
    topic = Fabricate(:topic, user: admin, category: category, title: title)
    Fabricate(:post, topic: topic, user: admin, post_number: 1)
    DiscussionBridge::FromDiscourseRecordCreator.call(
      user: admin,
      connection_id: connection.id,
      topic_id: topic.id,
      external_id: external_id,
      canonical_url: "https://cms-ui.example/#{external_id}/",
      lane: "news",
    ).record
  end

  it "opens an unconfigured off form without defaults, secrets, source discovery or nested forms" do
    open_configuration
    within(".discussion-bridge-cms-configuration") do
      expect(page).to have_unchecked_field("Enable publication for this destination")
      expect(page).to have_field("Actual native configuration version or revision", with: "")
      expect(page).to have_select("Native publication kind", selected: "Choose explicitly")
      expect(page).to have_select("Selected discussion presentation", selected: "Choose explicitly")
      expect(page).to have_content(
        "Native installation checks and public delivery results are not yet available",
      )
      expect(page).to have_content("Accepted native catalog selection is not available")
      expect(page).to have_no_css("form form")
    end
    expect(page.evaluate_script("document.querySelectorAll('form form').length")).to eq(0)
    expect(page.html.include?(@secret)).to eq(false)
    expect(@connection.reload.cms_configuration).to be_nil
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsMapping.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "allows explicit first-save enable and uses returned revision for the next native admin save" do
    open_configuration
    within(".discussion-bridge-cms-configuration") do
      configure_form
      check("Enable publication for this destination")
      click_button("Save CMS configuration")
      expect(page).to have_content("CMS configuration saved.", wait: 30)
    end
    stored = @connection.reload.cms_configuration
    first_revision = stored.fetch("policy").fetch("policy_revision")
    expect(stored.fetch("policy").fetch("enabled")).to eq(true)
    expect(stored.fetch("native_capabilities").fetch("native_revision")).to eq(
      "native:ui-author-fixture-1",
    )
    within(".discussion-bridge-cms-configuration") do
      check("Include eligible public unlisted topics")
      click_button("Save CMS configuration")
      expect(page).to have_content("CMS configuration saved.", wait: 30)
    end
    stored = @connection.reload.cms_configuration
    expect(stored.fetch("policy").fetch("include_unlisted")).to eq(true)
    expect(stored.fetch("policy").fetch("policy_revision")).not_to eq(first_revision)
  end

  it "saves explicit off configuration for To-only scope and the actual default empty lane" do
    @connection.update!(allowed_directions: ["to_discourse"], allowed_lanes: [])
    open_configuration
    within(".discussion-bridge-cms-configuration") do
      configure_form(lane: "Default connection lane")
      expect(page).to have_field("Enable publication for this destination", disabled: true)
      click_button("Save CMS configuration")
      expect(page).to have_content("CMS configuration saved.", wait: 30)
    end
    stored = @connection.reload.cms_configuration
    expect(stored.fetch("publication_lane")).to eq("")
    expect(stored.fetch("policy").fetch("enabled")).to eq(false)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "preserves unsaved edits on actual revision conflict until explicit reload" do
    save_configuration(configuration)
    open_configuration
    within(".discussion-bridge-cms-configuration") do
      fill_in("Actual native configuration version or revision", with: "native:my-unsaved-choice")
    end
    prior = @connection.reload.cms_configuration
    changed = configuration
    changed.fetch("native_capabilities")["native_revision"] = "native:other-admin-choice"
    save_configuration(changed, expected: prior.fetch("policy").fetch("policy_revision"))
    within(".discussion-bridge-cms-configuration") do
      click_button("Save CMS configuration")
      expect(page).to have_content("Configuration changed elsewhere.", wait: 30)
      expect(page).to have_field(
        "Actual native configuration version or revision",
        with: "native:my-unsaved-choice",
      )
      expect(page).to have_button("Save CMS configuration", disabled: true)
      click_button("Reload stored CMS configuration")
      expect(page).to have_field(
        "Actual native configuration version or revision",
        with: "native:other-admin-choice",
        wait: 30,
      )
    end
    expect(
      @connection.reload.cms_configuration.fetch("native_capabilities").fetch("native_revision"),
    ).to eq("native:other-admin-choice")
  end

  it "preserves stored unavailable category/catalog IDs and exact large decimal topic identities" do
    restricted = Fabricate(:category, read_restricted: true)
    value = configuration
    policy = value.fetch("policy")
    policy["selection"] = "categories"
    policy["category_ids"] = [category.id.to_s, restricted.id.to_s, "9223372036854775807"]
    policy["author_ids"] = ["native:author-retained"]
    policy["taxonomy_ids"] = ["native:taxonomy-retained"]
    save_configuration(value)
    open_configuration
    within(".discussion-bridge-cms-configuration") do
      expect(page).to have_content("Stored category 9223372036854775807 unavailable")
      expect(page).to have_content("#{restricted.name} — restricted category")
      expect(page).to have_content("native:author-retained")
      expect(page).to have_content("native:taxonomy-retained")
      fill_in("Explicitly included native topic IDs (one per line)", with: "9007199254740993")
      click_button("Save CMS configuration")
      expect(page).to have_content("CMS configuration saved.", wait: 30)
    end
    saved = @connection.reload.cms_configuration.fetch("policy")
    expect(saved.fetch("category_ids")).to eq(policy.fetch("category_ids"))
    expect(saved.fetch("author_ids")).to eq(policy.fetch("author_ids"))
    expect(saved.fetch("taxonomy_ids")).to eq(policy.fetch("taxonomy_ids"))
    expect(saved.fetch("include_topic_ids")).to eq(["9007199254740993"])
  end

  it "offers only real active owned From resources and retains unlisted allowlist identities until removal" do
    owned =
      owned_record(@connection, title: "Current owned resource", external_id: "owned-ui-entry")
    other, =
      DiscussionBridgeContentConnection.issue!(
        name: "Another native destination",
        platform: "hugo",
        allowed_origins: ["https://cms-ui.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
    unrelated =
      owned_record(other, title: "Another connection resource", external_id: "unrelated-ui-entry")
    stale = SecureRandom.uuid
    value = configuration
    value.fetch("policy")["existing_record_adoption"] = "explicit_records_only"
    value.fetch("policy")["adoptable_resource_ids"] = [stale]
    save_configuration(value)
    before = owned.attributes.deep_dup
    open_configuration
    within(".discussion-bridge-connection-card", text: @connection.public_id) do
      within(".discussion-bridge-cms-configuration form") do
        expect(page).to have_content(owned.resource_id, wait: 30)
        expect(page).to have_no_content(unrelated.resource_id)
        expect(page).to have_content(stale)
        find("label", text: owned.resource_id).find("input[type=checkbox]").check
        click_button("Save CMS configuration")
        expect(page).to have_content("CMS configuration saved.", wait: 30)
      end
    end
    expect(
      @connection.reload.cms_configuration.fetch("policy").fetch("adoptable_resource_ids"),
    ).to eq([stale, owned.resource_id])
    expect(owned.reload.attributes).to eq(before)
    expect(DiscussionBridgeCmsMapping.count).to eq(0)
  end

  # All credential observations return booleans/digests, never raw secrets in
  # assertions or artifact text. Always redact the displayed local fixture value
  # before any example failure can trigger native screenshot/HTML capture.
  # Update existing Text nodes; Element.textContent would detach Glimmer bindings.
  def redact_test_credential
    page.execute_script(<<~JS)
      document.querySelectorAll('.discussion-bridge-secret code').forEach((node) => {
        const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
        let textNode;
        while ((textNode = walker.nextNode())) {
          textNode.nodeValue = '[redacted local author fixture]';
        }
      });
    JS
  end

  def credential_probe
    try_until_success(timeout: 30) do
      expect(
        page.evaluate_script(
          "/^[A-Za-z0-9_-]{43}$/.test(document.querySelector('.discussion-bridge-secret__row:last-child code')?.textContent || '')",
        ),
      ).to eq(true)
    end
    page.evaluate_script(<<~JS)
      (async () => {
        const value = document.querySelector('.discussion-bridge-secret__row:last-child code').textContent;
        const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))).map((byte) => byte.toString(16).padStart(2, '0')).join('');
        const stored = (storage) => Object.keys(storage).some((key) => storage.getItem(key)?.includes(value));
        window.__discussionBridgeCredentialDigest = digest;
        const result = { shown: value.length >= 32, digest, localStored: stored(localStorage), sessionStored: stored(sessionStorage), copies: window.__discussionBridgeCopies.length };
        document.querySelectorAll('.discussion-bridge-secret code').forEach((node) => {
          const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
          let textNode;
          while ((textNode = walker.nextNode())) {
            textNode.nodeValue = '[redacted local author fixture]';
          }
        });
        return result;
      })()
    JS
  end

  it "keeps direct native create and rotate credentials ephemeral and copies only on administrator action" do
    open_connections
    page.execute_script(<<~JS)
      window.__discussionBridgeCopies = [];
      Object.defineProperty(navigator, 'clipboard', {
        configurable: true,
        value: {
          writeText: async (value) => {
            const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))).map((byte) => byte.toString(16).padStart(2, '0')).join('');
            window.__discussionBridgeCopies.push(digest === window.__discussionBridgeCredentialDigest);
          }
        }
      });
    JS
    fill_in("Connection name", with: "Native ephemeral credential fixture")
    select("hugo", from: "Platform")
    fill_in("Allowed origins (one per line)", with: "https://cms-secret.example")
    click_button("Add connection")
    created = credential_probe
    issued_connection =
      DiscussionBridgeContentConnection.find_by!(name: "Native ephemeral credential fixture")
    expect(created.fetch("digest") == issued_connection.secret_digest).to eq(true)
    expect(created.values_at("shown", "localStored", "sessionStored", "copies")).to eq(
      [true, false, false, 0],
    )
    find(".discussion-bridge-secret__row:last-child button").click
    redact_test_credential
    try_until_success do
      expect(page.evaluate_script("window.__discussionBridgeCopies")).to eq([true])
    end
    within(".discussion-bridge-connection-card", text: "Native ephemeral credential fixture") do
      click_button("Rotate credential")
    end
    prior_digest = issued_connection.reload.secret_digest
    rotation_path =
      "/discussion-bridge/admin/content-connections/#{issued_connection.id}/rotate-secret.json"
    page.driver.with_playwright_page do |native_page|
      response =
        native_page.expect_response(
          ->(observed) do
            observed.request.method == "POST" && URI.parse(observed.url).path == rotation_path
          end,
          timeout: 30_000,
        ) { within("#dialog-holder") { click_button("Yes") } }
      expect(response.status).to eq(200)
    end
    try_until_success(timeout: 30) do
      expect(issued_connection.reload.secret_digest != prior_digest).to eq(true)
    end
    rotated = credential_probe
    expect(rotated.fetch("digest") == issued_connection.secret_digest).to eq(true)
    expect(rotated.fetch("digest") == created.fetch("digest")).to eq(false)
    expect(rotated.values_at("shown", "localStored", "sessionStored", "copies")).to eq(
      [true, false, false, 1],
    )
    find(".discussion-bridge-secret__row:last-child button").click
    redact_test_credential
    try_until_success do
      expect(page.evaluate_script("window.__discussionBridgeCopies")).to eq([true, true])
    end
    page.execute_script("window.location.reload()")
    expect(page).to have_css(".discussion-bridge-connections", wait: 30)
    expect(page).to have_no_css(".discussion-bridge-secret")
  ensure
    redact_test_credential
  end
end
