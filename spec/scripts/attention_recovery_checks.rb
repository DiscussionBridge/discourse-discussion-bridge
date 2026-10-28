# frozen_string_literal: true
require_relative "../support/attention_recovery_fixture"

run("Check captures current closed context but does not create or reset Work") do
  service, _, _, work, actor, = fixture
  before = Marshal.dump(work.attributes)
  item = check(service, work, actor)
  assert(item.fetch("status") == "waiting", "not waiting")
  assert(DiscussionBridgeCmsWork.records.size == 1 && Marshal.dump(work.attributes) == before, "Check changed Work")
  DiscussionBridge::CmsProtocol.validate!("AttentionInspection", DiscussionBridgeCmsAttentionInspection.records.first.payload_tree)
end
run("identical Check action UUID replays exact inspection") do
  service, _, _, work, actor, = fixture
  input = {"mutation_id" => SecureRandom.uuid, "selected" => [{"work_id" => work.work_id, "mapping_revision" => work.cms_mapping.mapping_revision}]}
  one = service.check(actor: actor, input: input)
  two = service.check(actor: actor, input: input)
  assert(one.body == two.body && DiscussionBridgeCmsAttentionInspection.records.size == 1, "Check receipt did not replay")
end
run("factual report is read-only with respect to publication and idempotent") do
  service, _, _, work, actor, observation = fixture
  item = check(service, work, actor)
  before = Marshal.dump(work.attributes)
  outcome, inspection, body = report(service, item, observation)
  assert(outcome.body.fetch("status") == "ready", "qualified initial absence not ready")
  assert(service.report(inspection.inspection_id, body).body == outcome.body, "report replay changed")
  assert(work.state == "attention" && DiscussionBridgeCmsWork.records.size == 1 && Marshal.dump(work.attributes) == before, "report admitted Work")
  expect_error("mutation_conflict") { service.report(inspection.inspection_id, body.merge("observation" => observation.merge("native_state" => "unknown"))) }
end
run("explicit retry supersedes attention and appends one protected fresh cycle") do
  service, _, mapping, work, actor, observation = fixture
  _, inspection, = report(service, check(service, work, actor), observation)
  old_id, old_cycle = work.work_id, work.attempt_cycle
  input = retry_input(inspection)
  result = service.retry_selected(actor: actor, input: input)
  item = result.body.fetch("items").first
  assert(item.fetch("status") == "queued", item.inspect)
  new_work = DiscussionBridgeCmsWork.records.last
  recovery = DiscussionBridgeCmsAttentionRecovery.records.first
  assert(work.state == "superseded" && new_work.state == "pending" && new_work.attempt == 0, "not fresh pending cycle")
  assert(new_work.work_id != old_id && new_work.attempt_cycle != old_cycle && new_work.retry_of_work_id == work.id, "lineage/cycle lost")
  assert(new_work.lease_generation == 9 && mapping.fence_generation == 9, "admission incremented/reset fence")
  assert(recovery.attention_snapshot.fetch("work").fetch("state") == "attention", "old failure snapshot not preserved")
  assert(!recovery.attention_snapshot.fetch("work").key?("lease_verifier"), "private verifier retained")
  assert(service.retry_selected(actor: actor, input: input).body == result.body, "same action lost response replay failed")
  again = service.retry_selected(actor: actor, input: input.merge("mutation_id" => SecureRandom.uuid))
  assert(again.body.fetch("items").first.fetch("successor_work_id") == new_work.work_id && DiscussionBridgeCmsWork.records.size == 2, "repeat click created another successor")
end
run("ordinary claim cannot bypass positive recovery handoff; exact recovery claim advances fence") do
  service, conn, mapping, work, actor, observation = fixture
  _, inspection, = report(service, check(service, work, actor), observation)
  service.retry_selected(actor: actor, input: retry_input(inspection))
  recovery = DiscussionBridgeCmsAttentionRecovery.records.first
  coordinator = DiscussionBridge::CmsWorkCoordinator.new(conn, clock: -> { Time.current })
  ordinary = coordinator.claim({"mutation_id" => SecureRandom.uuid})
  assert(ordinary.status == 204 && recovery.successor_work.state == "pending", "ordinary claim bypassed positive recovery event")
  claim_input = {"mutation_id" => SecureRandom.uuid, "work_id" => recovery.successor_work.work_id}
  claimed = service.claim(recovery.recovery_id, claim_input)
  assert(claimed.status == 200 && claimed.body.fetch("work").fetch("work_id") == claim_input.fetch("work_id"), "wrong successor leased")
  assert(mapping.fence_generation == 10 && recovery.successor_work.lease_generation == 10, "fence did not advance monotonically")
  assert(service.claim(recovery.recovery_id, claim_input).body == claimed.body, "targeted claim receipt not exact")
end
run("stale source context refuses retry without resetting attention") do
  service, _, _, work, actor, observation = fixture
  _, inspection, = report(service, check(service, work, actor), observation)
  DiscussionBridge::CmsSourceStore.source = work.source_snapshot.merge("source_revision" => "new-source")
  item = service.retry_selected(actor: actor, input: retry_input(inspection)).body.fetch("items").first
  assert(item.fetch("status") == "stale" && work.state == "attention" && DiscussionBridgeCmsWork.records.size == 1, "stale source admitted")
end
run("newer Check invalidates earlier report and retry") do
  service, _, _, work, actor, observation = fixture
  _, inspection, = report(service, check(service, work, actor), observation)
  check(service, work, actor)
  item = service.retry_selected(actor: actor, input: retry_input(inspection)).body.fetch("items").first
  assert(item.fetch("status") == "stale" && DiscussionBridgeCmsWork.records.size == 1, "old inspection admitted")
end
run("metadata restoration indicator never automatically retries attention") do
  service, _, mapping, work, actor, = fixture
  work.update!(last_failure_code: "metadata_unavailable")
  before = Marshal.dump(work.attributes)
  assert(service.projection(mapping, work).fetch("metadata_restored"), "missing restoration indicator")
  assert(Marshal.dump(work.attributes) == before && DiscussionBridgeCmsWork.records.size == 1, "indicator retried Work")
end
run("actual current actor is reloaded and must remain native administrator") do
  service, _, _, work, actor, = fixture
  def actor.reload = (self.admin = false; self)
  begin
    check(service, work, actor)
    raise "revoked actor accepted"
  rescue Discourse::InvalidAccess
    assert(DiscussionBridgeCmsAttentionInspection.records.empty?, "revoked actor wrote inspection")
  end
end
run("current Guardian source visibility is required") do
  service, _, mapping, work, actor, = fixture
  mapping.content_binding.bridge_record.topic.visible = false
  item = check(service, work, actor)
  assert(item.fetch("status") == "conflict" && DiscussionBridgeCmsAttentionInspection.records.empty?, "invisible source wrote inspection or broke per-item results")
end
run("wrong secret and disabled policy cannot create inspections") do
  service, conn, _, work, actor, = fixture
  expect_error("authentication_failed") do
    DiscussionBridge::CmsAttentionRecovery.new(conn, authenticated_secret_digest: "x" * 64).capability
  end
  conn.cms_configuration.fetch("policy")["enabled"] = false
  expect_error("scope_denied") { check(service, work, actor) }
  assert(DiscussionBridgeCmsAttentionInspection.records.empty?, "disabled policy wrote inspection")
end
run("prepared static baseline requires named settlement and retains exact old transaction") do
  service, _, mapping, work, actor, observation = fixture("restored")
  old_transaction = mapping.prepared_transaction.deep_dup
  _, inspection, = report(service, check(service, work, actor), observation)
  refused = service.retry_selected(actor: actor, input: retry_input(inspection)).body.fetch("items").first
  assert(refused.fetch("status") == "conflict" && mapping.prepared_transaction == old_transaction, "generic retry cleared preparation")
  item = service.retry_selected(actor: actor, input: retry_input(inspection, settle: true)).body.fetch("items").first
  assert(item.fetch("status") == "queued" && mapping.prepared_transaction.nil?, "qualified named settlement failed")
  recovery = DiscussionBridgeCmsAttentionRecovery.records.first
  assert(recovery.mode == "settle_restored_baseline", "settlement not labelled")
  assert(recovery.attention_snapshot.fetch("mapping").fetch("prepared_transaction") == old_transaction, "old preparation lost")
  assert(mapping.native_result == mapping.verified_result.fetch("native_result"), "baseline projection not restored")
end
run("unknown native/uncertain mutation report remains Not ready and creates no successor") do
  service, _, _, work, actor, observation = fixture
  _, inspection, = report(service, check(service, work, actor), observation.merge("native_state" => "unknown", "pending_mutation" => "uncertain"))
  item = service.retry_selected(actor: actor, input: retry_input(inspection)).body.fetch("items").first
  assert(item.fetch("status") == "not_ready" && item.fetch("issue") == "uncertain_mutation" && work.state == "attention", "uncertain state admitted")
end
run("selected bulk checks return independent current outcomes") do
  service, _, mapping, work, actor, = fixture
  invalid = SecureRandom.uuid
  result = service.check(actor: actor, input: {"mutation_id" => SecureRandom.uuid,
    "selected" => [{"work_id" => invalid, "mapping_revision" => mapping.mapping_revision},
      {"work_id" => work.work_id, "mapping_revision" => mapping.mapping_revision}]}).body.fetch("items")
  assert(result.map { |item| item.fetch("status") } == %w[conflict waiting], "bulk did not isolate outcomes")
end
run("native closed parser rejects unknown fields, query parameters, oversized and duplicate JSON") do
  controller = DiscussionBridge::CmsAdminAttentionController.allocate
  request_class = Struct.new(:body, :headers, :query_string) { def post? = true }
  controller.define_singleton_method(:action_name) { "check" }
  valid = {"mutation_id" => SecureRandom.uuid, "selected" => [{"work_id" => SecureRandom.uuid, "mapping_revision" => "mapping-1"}]}
  request = request_class.new(StringIO.new(JSON.generate(valid)), {"Content-Type" => "application/json"}, "")
  controller.define_singleton_method(:request) { request }
  controller.send(:validate_input)
  assert(controller.instance_variable_get(:@input) == valid, "valid native JSON changed")
  request.query_string = "ready=true"
  expect_error("invalid_field") { controller.send(:validate_input) }
  request.query_string = ""
  request.body = StringIO.new(JSON.generate(valid.merge("ready" => true)))
  expect_error("unknown_field") { controller.send(:validate_input) }
  request.body = StringIO.new('{"mutation_id":"x","mutation_id":"y"}')
  expect_error { controller.send(:validate_input) }
  request.body = StringIO.new(" " * 65_537)
  expect_error { controller.send(:validate_input) }
end
run("source becomes unavailable after Check: safe stale evidence, no successor") do
  service, _, _, work, actor, observation = fixture
  _, inspection, = report(service, check(service, work, actor), observation)
  DiscussionBridge::CmsSourceStore.unavailable = true
  item = service.retry_selected(actor: actor, input: retry_input(inspection)).body.fetch("items").first
  assert(item.fetch("status") == "stale" && work.state == "attention" && DiscussionBridgeCmsWork.records.size == 1, "unavailable source admitted")
end
run("native selection bound rejects 26 entries before any effect") do
  service, _, mapping, work, actor, = fixture
  expect_error do
    service.check(actor: actor, input: {"mutation_id" => SecureRandom.uuid,
      "selected" => 26.times.map { {"work_id" => SecureRandom.uuid, "mapping_revision" => mapping.mapping_revision} }})
  end
  assert(DiscussionBridgeCmsAttentionInspection.records.empty?, "oversized selection wrote")
end
run("pending and retry_wait cannot enter attention recovery") do
  %w[pending retry_wait verified cancelled superseded].each do |state|
    service, _, _, work, actor, = fixture
    work.state = state
    result = check(service, work, actor)
    assert(result.fetch("status") == "conflict" && DiscussionBridgeCmsAttentionInspection.records.empty?, "#{state} admitted recovery")
  end
end
run("unknown/foreign recovery claim and stale target cannot lease other Work") do
  service, _, _, work, actor, observation = fixture
  _, inspection, = report(service, check(service, work, actor), observation)
  service.retry_selected(actor: actor, input: retry_input(inspection))
  recovery = DiscussionBridgeCmsAttentionRecovery.records.first
  expect_error("resource_not_found") { service.claim(SecureRandom.uuid, {"mutation_id" => SecureRandom.uuid, "work_id" => work.work_id}) }
  expect_error("identity_conflict") { service.claim(recovery.recovery_id, {"mutation_id" => SecureRandom.uuid, "work_id" => work.work_id}) }
  assert(recovery.successor_work.state == "pending", "foreign claim leased successor")
end
run("same-intent cancelled hold is excluded from Check and unchanged") do
  service, _, _, work, actor, = fixture
  work.update!(state: "cancelled", same_intent_hold: true)
  result = check(service, work, actor)
  assert(result.fetch("status") == "conflict" && work.same_intent_hold? && work.state == "cancelled", "cancelled hold cleared")
end
run("inspection feed is increasing, bounded, resumable and does not admit Work") do
  service, _, _, work, actor, = fixture
  27.times { check(service, work, actor) }
  before = Marshal.dump(work.attributes)
  first = service.inspections(after: 0).body
  assert(first.fetch("items").length == 25 && first.fetch("has_more") && first.fetch("next_after") == 25, "first feed page wrong")
  second = service.inspections(after: first.fetch("next_after")).body
  assert(second.fetch("items").map { |item| item.fetch("sequence") } == [26, 27] && !second.fetch("has_more"), "continuation order wrong")
  empty = service.inspections(after: second.fetch("next_after")).body
  assert(empty == {"items" => [], "next_after" => 27, "has_more" => false}, "empty cursor advanced/repeated")
  assert(Marshal.dump(work.attributes) == before && DiscussionBridgeCmsWork.records.size == 1, "poll admitted publication")
end
run("recovery feed carries exact positive successor/context and remains replayable") do
  service, _, _, work, actor, observation = fixture
  _, inspection, = report(service, check(service, work, actor), observation)
  service.retry_selected(actor: actor, input: retry_input(inspection))
  page = service.recoveries(after: 0).body
  item = page.fetch("items").first
  assert(item.fetch("predecessor_work_id") == work.work_id && item.fetch("work").fetch("state") == "pending", "positive handoff missing")
  assert(item.fetch("inspection_id") == inspection.inspection_id && item.fetch("context_sha256") == inspection.context_sha256, "context handoff missing")
  assert(service.recoveries(after: 0).body == page, "feed replay changed immutable handoff")
end
run("cross-page feed helper rejects repeated/descending positions and false empty advancement") do
  page = {"items" => [], "next_after" => 4, "has_more" => false}
  expect_error { DiscussionBridge::CmsProtocol.validate_attention_feed_page!("AttentionInspectionPage", page, 3) }
  expect_error { DiscussionBridge::CmsProtocol.validate_attention_feed_page!("AttentionInspectionPage", page.merge("has_more" => true), 4) }
  service, _, _, work, actor, = fixture
  check(service, work, actor)
  one = service.inspections(after: 0).body
  expect_error { DiscussionBridge::CmsProtocol.validate_attention_feed_page!("AttentionInspectionPage", one, 1) }
end
run("older preparation from a different Work/source/policy is Not ready without invalid inspection; selected independent row proceeds") do
  service, conn, mapping, work, actor, = fixture
  prepared = FIXTURES.fetch("restored").fetch("inspection").fetch("prepared_transaction").deep_dup
  prepared.merge!("work_id" => SecureRandom.uuid, "source_revision" => "prior-source", "policy_revision" => "prior-policy")
  mapping.prepared_transaction = prepared
  source = work.source_snapshot.merge("source_id" => "topic:54", "topic_id" => "54", "topic_url" => "https://forum.example/t/other/54")
  record = Row.new(resource_id: SecureRandom.uuid, direction: "from_discourse", lane: "news", topic: Row.new(id: 54, visible: true))
  binding = Row.new(content_connection_id: conn.id, role: "presentation", state: "active", bridge_record: record,
    canonical_url: "https://astro.example/other/", external_id: "other")
  other_mapping = DiscussionBridgeCmsMapping.create!(**mapping.instance_variable_get(:@attrs).except(:id),
    mapping_id: SecureRandom.uuid, source_id: "topic:54", content_binding: binding, prepared_transaction: nil)
  other = DiscussionBridgeCmsWork.create!(**work.instance_variable_get(:@attrs).except(:id),
    work_id: SecureRandom.uuid, attempt_cycle: SecureRandom.uuid, cms_mapping_id: other_mapping.id, source_snapshot: source)
  DiscussionBridge::CmsSourceStore.source = {53 => work.source_snapshot, 54 => source}
  result = service.check(actor: actor, input: {"mutation_id" => SecureRandom.uuid, "selected" => [work, other].map do |item|
    {"work_id" => item.work_id, "mapping_revision" => item.cms_mapping.mapping_revision}
  end}).body.fetch("items")
  assert(result.map { |item| item.fetch("status") } == %w[not_ready waiting], result.inspect)
  assert(result.first.fetch("issue") == "context_changed" && result.first.fetch("inspection_id").nil?, "cross-intent created invalid evidence")
  assert(mapping.prepared_transaction == prepared && work.state == "attention" && DiscussionBridgeCmsWork.records.size == 2, "cross-intent cleared preparation/admitted cycle")
  assert(DiscussionBridgeCmsAttentionInspection.records.size == 1 && DiscussionBridgeCmsAttentionInspection.records.first.cms_work_id == other.id, "invalid inspection leaked")
end
run("connector transport rejects malformed and duplicate queries/GET bodies before typed input") do
  controller = DiscussionBridge::CmsAttentionController.allocate
  request_class = Struct.new(:body, :headers, :query_string) { def get? = true }
  request = request_class.new(StringIO.new(""), {}, "after=1&after=2")
  controller.define_singleton_method(:request) { request }
  controller.define_singleton_method(:action_name) { "inspections" }
  expect_error("invalid_field") { controller.send(:validate_transport) }
  request.query_string = "after=%ZZ"
  expect_error("invalid_field") { controller.send(:validate_transport) }
  request.query_string = "after=2"
  controller.send(:validate_transport);controller.send(:validate_typed_input)
  assert(controller.instance_variable_get(:@after) == 2, "cursor normalization wrong")
  request.body = StringIO.new("{}")
  expect_error("invalid_field") { controller.send(:validate_transport) }
  request.body = StringIO.new("");request.query_string = "ready=true"
  controller.send(:validate_transport)
  expect_error("unknown_field") { controller.send(:validate_typed_input) }
end
run("connector parent authentication never substitutes a native session or body authority") do
  _, conn, = fixture
  controller = DiscussionBridge::CmsAttentionController.allocate
  request = Struct.new(:headers).new({})
  controller.define_singleton_method(:request) { request }
  expect_error("authentication_required") { controller.send(:authenticate_content_connection) }
  request.headers.merge!("X-DiscussionBridge-Connection" => conn.public_id, "X-DiscussionBridge-Secret" => "wrong")
  expect_error("authentication_failed") { controller.send(:authenticate_content_connection) }
  request.headers["X-DiscussionBridge-Secret"] = "synthetic-cms-secret"
  controller.send(:authenticate_content_connection)
  assert(controller.instance_variable_get(:@content_connection).equal?(conn) && controller.instance_variable_get(:@authenticated_secret_digest) == conn.secret_digest, "authenticated binding missing")
end
run("native attention JSON transport is guarded before Rails body parsing") do
  calls = 0
  guard = DiscussionBridge::CmsJsonTransportGuard.new(->(_env) { calls += 1; [204, {}, []] })
  env = {"PATH_INFO" => "/admin/content-connections/1/cms-attention/check.json", "REQUEST_METHOD" => "POST",
    "CONTENT_TYPE" => "application/json", "rack.input" => StringIO.new('{"mutation_id":"x","mutation_id":"y"}')}
  status, _, = guard.call(env)
  assert(status != 204 && calls == 0, "duplicate native body reached Rails")
  env["rack.input"] = StringIO.new("{}")
  assert(guard.call(env).first == 204 && calls == 1, "well-formed transport blocked before native authority check")
end
puts JSON.pretty_generate(checks: CHECKS.length, passed: CHECKS, failures: FAILURES, runtime: RUBY_DESCRIPTION,
  boundary: "Actual CmsAttentionRecovery/CmsWorkCoordinator/CmsProtocol/CmsConfiguration/CmsAuthorityLifecycle/CmsMappingProjection/CmsSourceStore.scope_fingerprint/native admin parser; process-local model/relations, encryption, source-capture, catalog inventory, Core framework and Guardian fixtures. SQL filtering, transactions/rollback/unique constraints, Rails auth/CSRF, migrations, actual notifications and browser unexecuted.")
exit(FAILURES.empty? ? 0 : 1)
