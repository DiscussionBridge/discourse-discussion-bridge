# frozen_string_literal: true

require "rails_helper"

# Actual Core/Capybara/Playwright rendering and AJAX against local Rails/SQL.
# Only native-owner observations/public proofs below are synthetic typed facts.
# No CMS write or anonymous public-URL qualification is claimed by these tests.
# Phil approved Core's standard local browser server for these admin cases.
# Canonical source URLs still come from actual Core HTTPS settings and are
# asserted below. Actual HTTPS transport is a separate protected-sandbox gate;
# neither Topic.url/Discourse.base_url nor the product Url schema is replaced.
RSpec.describe "DiscussionBridge native attention administration" do
  PANEL = "/admin/plugins/discourse-discussion-bridge/connections"
  CHECK = "Check native state"
  CHECK_SELECTED = "Check native state for selected"
  RETRY_SELECTED = "Retry ready selected"
  SETTLE = "Settle restored baseline and retry"
  WAITING = "Waiting for adapter"
  READY = "Ready as inspected; native state is checked again before writing"
  QUEUED = "Retry queued; publication not yet verified"
  NOTICE = "DiscussionBridge publication needs administrator attention"

  fab!(:admin)
  fab!(:ordinary_user, :user)

  before do
    # The existing asynchronous source wake is isolated, exactly as in the
    # native request regressions; capture/coordinator/controllers stay real.
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    # Core's standard system server is HTTP. Leaving force_https enabled here
    # makes Core issue Secure auth cookies that this server cannot send back.
    # publication enables it only while capturing actual canonical source URLs.
    SiteSetting.force_https = false
    SiteSetting.login_required = false
    @page_errors = []
    @attention_posts = []
    page.driver.with_playwright_page do |pw_page|
      pw_page.on("pageerror", ->(error) { @page_errors << error.message })
      pw_page.on("request", lambda do |request|
        if request.method == "POST" && request.url.include?("/cms-attention/")
          @attention_posts << { "url" => request.url, "body" => request.post_data }
        end
      end)
    end
    @connection, @secret = issue_connection
    @mapping = publication(@connection, "first")
    @work = attention!(@mapping)
    sign_in(admin)
    expect(URI(page.current_url).host).to eq(Capybara.server_host)
    expect(URI(page.current_url).port).to eq(Capybara.server_port)
    expect(page).to have_css(".header-dropdown-toggle.current-user")
  end

  after do
    expect(@page_errors).to be_empty
  end

  def issue_connection(profile: "ghost", kind: "dynamic")
    connection, secret = DiscussionBridgeContentConnection.issue!(
      name: "UI attention #{profile} #{SecureRandom.hex(6)}", platform: profile,
      allowed_origins: ["https://site.example"], allowed_directions: ["from_discourse"], allowed_lanes: ["news"],
    )
    connection.update!(cms_configuration: {
      "profile" => profile, "destination_origin" => "https://site.example", "publication_lane" => "news",
      "native_capabilities" => { "native_revision" => "native:ui-fixture", "supported_presentations" => %w[simple full],
        "publication_kind" => kind, "complete_content_supported" => true },
      "policy" => { "policy_revision" => SecureRandom.uuid, "enabled" => true, "selection" => "all_public",
        "category_ids" => [], "include_topic_ids" => [], "exclude_topic_ids" => [], "include_unlisted" => false,
        "publication_kind" => kind, "presentation_mode" => "simple", "author_ids" => [], "taxonomy_ids" => [] },
    })
    [connection, secret]
  end

  def publication(connection, name)
    previous_force_https = SiteSetting.force_https
    SiteSetting.force_https = true
    topic = Fabricate(:topic, user: admin, title: "Native UI attention #{name}")
    Fabricate(:post, topic: topic, user: admin, post_number: 1,
      raw: "Native UI source #{name}.", cooked: "<p>Native UI source #{name}.</p>")
    result = DiscussionBridge::FromDiscourseRecordCreator.call(user: admin, connection_id: connection.id,
      topic_id: topic.id, external_id: "ui-#{name}", canonical_url: "https://site.example/ui-#{name}/")
    mapping = DiscussionBridgeCmsMapping.find_by!(content_binding_id: result.record.active_binding("presentation").id)
    source_url = mapping.work_items.order(:id).last.source_snapshot.fetch("topic_url")
    expect(Discourse.base_url).to start_with("https://")
    expect(source_url).to eq(topic.url)
    expect(URI(source_url).scheme).to eq("https")
    expect(URI(source_url).host).to eq(URI(Discourse.base_url).host)
    DiscussionBridge::CmsProtocol.validate!("Url", source_url)
    mapping
  ensure
    SiteSetting.force_https = previous_force_https
  end

  def authority(lease)
    work = lease.fetch("work")
    { "work_id" => work.fetch("work_id"), "lease_token" => lease.fetch("lease_token"),
      "lease_generation" => lease.fetch("lease_generation"), "source_revision" => work.fetch("source_revision"),
      "policy_revision" => work.fetch("policy_revision") }
  end

  def attention!(mapping, code: "native_ownership_conflict")
    coordinator = DiscussionBridge::CmsWorkCoordinator.new(mapping.content_connection)
    lease = coordinator.claim({ "mutation_id" => SecureRandom.uuid, "mapping_id" => mapping.mapping_id }).body
    expect(lease).to be_present
    coordinator.fail(lease.fetch("work").fetch("work_id"), {
      "mutation_id" => SecureRandom.uuid, "authority" => authority(lease), "code" => code,
      "native_change_applied" => false, "safe_detail" => nil, "retry_after_seconds" => nil,
    })
    mapping.work_items.order(:id).last.reload
  end

  def open_panel(connection = @connection)
    visit PANEL
    expect(page).to have_current_path(PANEL)
    expect(page).to have_css(".discussion-bridge-connection-card", text: connection.name)
    within(card(connection)) { click_button "CMS publication configuration" }
    expect(delivery(connection)).to have_content("CMS delivery status")
    expect(delivery(connection)).to have_no_content("Loading retained delivery facts…")
  end

  def card(connection = @connection)
    find(".discussion-bridge-connection-card", text: connection.name)
  end

  def delivery(connection = @connection)
    card(connection).find(".discussion-bridge-cms-delivery")
  end

  def row(mapping)
    delivery(mapping.content_connection).find("article[data-mapping-id='#{mapping.mapping_id}']")
  end

  def reload_delivery(connection = @connection)
    within(delivery(connection)) { click_button "Reload delivery status" }
    expect(delivery(connection)).to have_no_content("Loading retained delivery facts…")
  end

  def select_row(mapping)
    row(mapping).find("input[type='checkbox']").check
  end

  def inspection_for(mapping)
    inspection = nil
    try_until_success do
      inspection = DiscussionBridgeCmsAttentionInspection.where(cms_mapping_id: mapping.id).order(:id).last
      expect(inspection).to be_present
    end
    inspection
  end

  def check_from_browser(mapping)
    within(row(mapping)) { click_button CHECK, exact: true }
    expect(row(mapping)).to have_content(WAITING)
    inspection_for(mapping)
  end

  def initial_absence(profile: "ghost-dynamic-1")
    { "profile" => profile, "observed_at" => Time.current.utc.iso8601(3), "native_state" => "never_applied",
      "object_exists" => false, "native_id" => nil, "native_revision" => nil, "ownership" => nil,
      "native_result" => nil, "verification" => nil, "source_revision" => nil, "managed_content_sha256" => nil,
      "native_command" => "none", "pending_mutation" => "none", "prepared_transaction_id" => nil,
      "journal_sha256" => "a" * 64, "baseline_sha256" => nil, "candidate_sha256" => nil,
      "current_sha256" => nil, "restoration_operation_id" => nil, "issue" => "none" }
  end

  def report_observation(mapping, inspection, observation)
    # The sole native-owner seam: actual typed Ruby report/classification and
    # persistence. No fake UI/API response is fulfilled into the browser.
    DiscussionBridge::CmsAttentionRecovery.new(mapping.content_connection,
      authenticated_secret_digest: mapping.content_connection.secret_digest).report(inspection.inspection_id, {
      "mutation_id" => SecureRandom.uuid, "context_sha256" => inspection.context_sha256, "observation" => observation,
    })
  end

  def ready_from_browser(mapping)
    inspection = check_from_browser(mapping)
    result = report_observation(mapping, inspection, initial_absence)
    expect(result.body.fetch("status")).to eq("ready")
    reload_delivery(mapping.content_connection)
    expect(row(mapping)).to have_content(READY)
    inspection.reload
  end

  def assert_one_successor(work)
    recovery = DiscussionBridgeCmsAttentionRecovery.find_by!(predecessor_work_id: work.id)
    expect(DiscussionBridgeCmsAttentionRecovery.where(predecessor_work_id: work.id).count).to eq(1)
    expect(work.reload.state).to eq("superseded")
    successor = recovery.successor_work.reload
    expect(successor).to have_attributes(state: "pending", attempt: 0, retry_of_work_id: work.id)
    expect(successor.work_id).not_to eq(work.work_id)
    expect(successor.attempt_cycle).not_to eq(work.attempt_cycle)
    expect(successor.source_snapshot).to eq(work.source_snapshot)
    recovery
  end

  def native_result(mapping, digest:, revision:, receipt:)
    { "kind" => "publish_revision", "native_id" => "fixture:#{mapping.id}",
      "external_id" => mapping.content_binding.external_id, "canonical_url" => mapping.content_binding.canonical_url,
      "native_revision" => revision, "ownership_receipt_sha256" => receipt,
      "representation" => { "kind" => "full", "source_content_sha256" => digest } }
  end

  def public_proof(mapping, result, source_revision)
    { "kind" => "published", "url" => mapping.content_binding.canonical_url,
      "native_id" => result.fetch("native_id"), "source_revision" => source_revision,
      "source_content_sha256" => result.fetch("representation").fetch("source_content_sha256"),
      "native_publication_sha256" => "e" * 64, "verification_profile" => "synthetic:no-http",
      "checked_at" => Time.current.utc.iso8601(3), "representation" => result.fetch("representation") }
  end

  def prepared_static
    connection, = issue_connection(profile: "astro", kind: "static")
    mapping = publication(connection, "static")
    work = mapping.work_items.order(:id).last
    revision = "baseline:ui"
    baseline = native_result(mapping, digest: Digest::SHA256.hexdigest("earlier UI source"), revision: "native:baseline", receipt: "b" * 64)
    mapping.update!(destination_native_id: baseline.fetch("native_id"), destination_native_revision: baseline.fetch("native_revision"),
      synchronized_source_revision: revision, publicly_verified_source_revision: revision,
      native_result: baseline, verified_result: { "native_result" => baseline, "verification" => public_proof(mapping, baseline, revision) },
      synchronized_at: 2.minutes.ago, publicly_verified_at: 1.minute.ago)
    coordinator = DiscussionBridge::CmsWorkCoordinator.new(connection)
    lease = coordinator.claim({ "mutation_id" => SecureRandom.uuid, "mapping_id" => mapping.mapping_id }).body
    candidate = native_result(mapping, digest: work.source_snapshot.fetch("content_sha256"), revision: "native:candidate", receipt: "c" * 64)
    transaction_id = SecureRandom.uuid
    coordinator.prepare(work.work_id, { "mutation_id" => SecureRandom.uuid, "authority" => authority(lease),
      "transaction_id" => transaction_id, "native_result" => candidate, "prepared_at" => Time.current.utc.iso8601(3) })
    coordinator.fail(work.work_id, { "mutation_id" => SecureRandom.uuid, "authority" => authority(lease),
      "code" => "native_restore_required", "native_change_applied" => true, "safe_detail" => nil, "retry_after_seconds" => nil })
    observation = initial_absence(profile: "astro-static-1").merge(
      "native_state" => "restored_baseline", "object_exists" => true, "native_id" => baseline.fetch("native_id"),
      "native_revision" => baseline.fetch("native_revision"), "native_result" => baseline,
      "ownership" => { "resource_id" => mapping.content_binding.bridge_record.resource_id,
        "external_id" => mapping.content_binding.external_id, "native_id" => baseline.fetch("native_id"),
        "canonical_url" => mapping.content_binding.canonical_url, "source_revision" => revision,
        "ownership_receipt_sha256" => baseline.fetch("ownership_receipt_sha256") },
      "verification" => public_proof(mapping, baseline, revision), "source_revision" => revision,
      "managed_content_sha256" => "d" * 64, "prepared_transaction_id" => transaction_id,
      "baseline_sha256" => "f" * 64, "current_sha256" => "f" * 64,
    )
    [connection, mapping.reload, work.reload, observation]
  end

  def focus_snapshot
    page.evaluate_script(<<~JS)
      (() => { const e = document.activeElement; return {
        tag: e.tagName, id: e.id, text: (e.innerText || e.getAttribute('aria-label') || '').slice(0, 160),
        inPanel: Boolean(e.closest('.discussion-bridge-cms-configuration')),
        interactive: e.matches('a[href],button,input,select,textarea,[tabindex]'),
        disabled: Boolean(e.disabled), connected: e.isConnected
      }; })()
    JS
  end

  it "renders per-item Check results without admitting work or resetting attention" do
    blocked_mapping = publication(@connection, "blocked")
    blocked_work = attention!(blocked_mapping)
    before = [@work.reload.attributes.deep_dup, blocked_work.attributes.deep_dup]
    open_panel
    select_row(@mapping)
    select_row(blocked_mapping)
    within(delivery) { click_button CHECK_SELECTED, exact: true }
    expect(row(@mapping)).to have_content(WAITING)
    expect(row(blocked_mapping)).to have_content(WAITING)
    first = inspection_for(@mapping)
    blocked = inspection_for(blocked_mapping)
    expect(report_observation(@mapping, first, initial_absence).body.fetch("status")).to eq("ready")
    unsupported = initial_absence.merge("native_state" => "unknown", "issue" => "native_conflict")
    expect(report_observation(blocked_mapping, blocked, unsupported).body.fetch("status")).to eq("not_ready")
    reload_delivery
    expect(row(@mapping)).to have_content(READY)
    expect(row(blocked_mapping)).to have_content("Not ready")
    expect(row(blocked_mapping)).to have_no_button("Retry", exact: true)
    expect([@work.reload.attributes, blocked_work.reload.attributes]).to eq(before)
    expect(DiscussionBridgeCmsAttentionRecovery.count).to eq(0)
    expect(@mapping.work_items.count).to eq(1)
    expect(blocked_mapping.work_items.count).to eq(1)
  end

  it "admits an individual Retry as one linked pending cycle and preserves native identity" do
    open_panel
    ready_from_browser(@mapping)
    identity = [@mapping.mapping_id, @mapping.content_binding.bridge_record.resource_id,
      @mapping.content_binding.canonical_url, @mapping.destination_native_id]
    within(row(@mapping)) { click_button "Retry", exact: true }
    expect(delivery).to have_content(QUEUED)
    recovery = assert_one_successor(@work)
    expect(recovery.mode).to eq("retry")
    expect(@mapping.work_items.count).to eq(2)
    expect([@mapping.reload.mapping_id, @mapping.content_binding.bridge_record.resource_id,
      @mapping.content_binding.canonical_url, @mapping.destination_native_id]).to eq(identity)
    expect(row(@mapping)).to have_no_button("Retry", exact: true)
    expect(row(@mapping)).to have_content("Pending")
    expect(row(@mapping)).to have_no_content("Current desired revision publicly verified")
  end

  it "retries only selected ready bulk rows and leaves blocked and unselected rows in attention" do
    blocked_mapping = publication(@connection, "bulk-blocked")
    blocked_work = attention!(blocked_mapping)
    unselected_mapping = publication(@connection, "bulk-unselected")
    unselected_work = attention!(unselected_mapping)
    open_panel
    ready_from_browser(@mapping)
    ready_from_browser(unselected_mapping)
    blocked = check_from_browser(blocked_mapping)
    report_observation(blocked_mapping, blocked, initial_absence.merge("native_state" => "unknown", "issue" => "native_conflict"))
    reload_delivery
    select_row(@mapping)
    select_row(blocked_mapping)
    within(delivery) { click_button RETRY_SELECTED, exact: true }
    expect(delivery).to have_content(QUEUED)
    assert_one_successor(@work)
    expect(blocked_work.reload.state).to eq("attention")
    expect(unselected_work.reload.state).to eq("attention")
    expect(blocked_mapping.work_items.count).to eq(1)
    expect(unselected_mapping.work_items.count).to eq(1)
    expect(DiscussionBridgeCmsAttentionRecovery.count).to eq(1)
    submitted = JSON.parse(@attention_posts.select { |entry| entry.fetch("url").include?("/retry.json") }.last.fetch("body"))
    expect(submitted.fetch("selected").length).to eq(1)
    expect(submitted.fetch("selected").first.fetch("settle_restored_baseline")).to eq(false)
  end

  it "replays the exact committed-but-lost Retry request without creating a duplicate cycle" do
    open_panel
    ready_from_browser(@mapping)
    pattern = "**/admin/content-connections/#{@connection.id}/cms-attention/retry.json"
    forwarded = []
    transport_errors = []
    handler = lambda do |route, _request|
      begin
        # Forward the actual browser method, cookies, CSRF header and raw body
        # to this real Rails server. Only its already-produced response is lost.
        upstream = route.fetch(maxRedirects: 0, maxRetries: 0,
          timeout: Capybara.default_max_wait_time * 1000)
        forwarded << { "status" => upstream.status, "body" => route.request.post_data }
      rescue StandardError => error
        transport_errors << "#{error.class}: #{error.message}"
      ensure
        route.abort(errorCode: "failed")
      end
    end
    page.driver.with_playwright_page { |pw_page| pw_page.route(pattern, handler, times: 1) }
    within(row(@mapping)) { click_button "Retry", exact: true }
    dialog = PageObjects::Components::Dialog.new
    expect(dialog).to be_open
    expect(transport_errors).to be_empty
    expect(forwarded.length).to eq(1)
    expect(forwarded.first.fetch("status")).to eq(200)
    first_recovery = assert_one_successor(@work)
    dialog.click_ok
    expect(dialog).to be_closed
    # The browser has not received success; it still offers the old ready row.
    expect(row(@mapping)).to have_button("Retry", exact: true)
    within(row(@mapping)) { click_button "Retry", exact: true }
    expect(delivery).to have_content(QUEUED)
    expect(assert_one_successor(@work).id).to eq(first_recovery.id)
    expect(@mapping.work_items.count).to eq(2)
    requests = @attention_posts.select { |entry| entry.fetch("url").include?("/retry.json") }
    expect(requests.length).to eq(2)
    expect(requests.map { |entry| entry.fetch("body") }.uniq).to eq([forwarded.first.fetch("body")])
    expect(JSON.parse(requests.first.fetch("body")).fetch("mutation_id")).to be_present
  ensure
    page.driver.with_playwright_page { |pw_page| pw_page.unroute(pattern, handler: handler) } if pattern && handler
  end

  it "keeps restored metadata manual when the panel opens and delivery facts reload" do
    metadata_mapping = publication(@connection, "metadata-restored")
    metadata_work = attention!(metadata_mapping, code: "metadata_unavailable")
    before = metadata_work.attributes.deep_dup
    open_panel
    expect(row(metadata_mapping)).to have_content("Metadata restored—admin review required")
    reload_delivery
    expect(row(metadata_mapping)).to have_content("Metadata restored—admin review required")
    expect(@attention_posts).to be_empty
    expect(metadata_work.reload.attributes).to eq(before)
    expect(metadata_mapping.work_items.count).to eq(1)
    expect(DiscussionBridgeCmsAttentionInspection.where(cms_work_id: metadata_work.id)).to be_empty
    expect(DiscussionBridgeCmsAttentionRecovery.where(predecessor_work_id: metadata_work.id)).to be_empty
    check_from_browser(metadata_mapping)
    expect(metadata_work.reload.attributes).to eq(before)
    expect(metadata_mapping.work_items.count).to eq(1)
  end

  it "offers the distinct named static settlement and archives only its exact retained preparation" do
    connection, mapping, work, observation = prepared_static
    preparation = mapping.prepared_transaction.deep_dup
    open_panel(connection)
    inspection = check_from_browser(mapping)
    expect(report_observation(mapping, inspection, observation).body.fetch("status")).to eq("ready")
    reload_delivery(connection)
    expect(row(mapping)).to have_content("This action archives the exact old preparation")
    expect(row(mapping)).to have_content("It does not restore native files or adopt an applied candidate.")
    expect(row(mapping)).to have_no_button("Retry", exact: true)
    expect(work.reload.state).to eq("attention")
    expect(mapping.reload.prepared_transaction).to eq(preparation)
    within(row(mapping)) { click_button SETTLE, exact: true }
    expect(delivery(connection)).to have_content(QUEUED)
    recovery = assert_one_successor(work)
    expect(recovery.mode).to eq("settle_restored_baseline")
    expect(mapping.reload.prepared_transaction).to be_nil
    retained = DiscussionBridge::CmsReceiptCipher.decrypt(recovery.attention_snapshot)
    expect(retained.fetch("mapping").fetch("prepared_transaction")).to eq(preparation)
    submitted = JSON.parse(@attention_posts.select { |entry| entry.fetch("url").include?("/retry.json") }.last.fetch("body"))
    expect(submitted.fetch("selected").first.fetch("settle_restored_baseline")).to eq(true)
  end

  it "renders a protected native bell with normal read state and no publishing side effect" do
    DiscussionBridge::CmsAttentionNotifications.dispatch
    notice = DiscussionBridgeCmsAttentionNotice.find_by!(cms_work_id: @work.id)
    recipient = DiscussionBridgeCmsAttentionDelivery.find_by!(notice_id: notice.id, user_id: admin.id)
    notification = Notification.find(recipient.notification_id)
    expect(notification.read).to eq(false)
    before = @work.reload.attributes.deep_dup
    visit "/latest"
    user_menu = PageObjects::Components::UserMenu.new
    user_menu.open
    expect(page).to have_css(".user-menu .notification a[href='#{PANEL}']", text: NOTICE)
    within(".user-menu") do
      expect(page).to have_no_content(@secret)
      expect(page).to have_no_content(@mapping.content_binding.bridge_record.topic.title)
    end
    # Native keyboard activation exercises the actual notification click/read
    # path as well as the plugin renderer's protected destination.
    find(".user-menu .notification a[href='#{PANEL}']", text: NOTICE).send_keys(:enter)
    expect(page).to have_current_path(PANEL)
    expect(page).to have_css(".discussion-bridge-connection-card", text: @connection.name)
    try_until_success { expect(notification.reload.read).to eq(true) }
    expect(@work.reload.attributes).to eq(before)
    expect(@mapping.work_items.count).to eq(1)
    expect(DiscussionBridgeCmsAttentionRecovery.count).to eq(0)
    DiscussionBridge::CmsAttentionNotifications.dispatch
    expect(DiscussionBridgeCmsAttentionDelivery.where(notice_id: notice.id, user_id: admin.id).count).to eq(1)
    expect(recipient.reload.notification_id).to eq(notification.id)
    sign_in(ordinary_user)
    visit PANEL
    expect(page).to have_no_css(".discussion-bridge-connection-card")
    expect(page).to have_no_css(".discussion-bridge-cms-delivery")
    expect(@work.reload.attributes).to eq(before)
  end

  it "allows keyboard Check and logical enabled navigation after delivery refresh" do |example|
    open_panel
    within(row(@mapping)) { find_button(CHECK, exact: true).send_keys(:enter) }
    expect(row(@mapping)).to have_content(WAITING)
    expect(@work.reload.state).to eq("attention")
    after_action = focus_snapshot
    page.driver.with_playwright_page { |pw_page| pw_page.keyboard.press("Tab") }
    after_tab = focus_snapshot
    example.metadata[:attention_focus] = { after_action: after_action, after_tab: after_tab }
    puts "ATTENTION_KEYBOARD_FOCUS #{JSON.generate(example.metadata[:attention_focus])}"
    # Body focus alone is not a finding. The next native Tab must reach an
    # enabled local control, not strand the operator or silently restart elsewhere.
    expect(after_tab).to include("inPanel" => true, "interactive" => true, "disabled" => false, "connected" => true)
    expect(DiscussionBridgeCmsAttentionRecovery.count).to eq(0)
  end
end
