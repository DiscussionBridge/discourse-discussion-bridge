# frozen_string_literal: true
require_relative "../support/attention_recovery_fixture"

def withdrawn_fixture(exists: false, restored: false, profile: "hugo")
  item = Marshal.load(Marshal.dump(FIXTURES.fetch("restored")))
  inspection = item.fetch("inspection")
  observation = item.fetch("observation")
  baseline = inspection.fetch("verified_native_result").except("representation").merge(
    "kind" => "withdraw", "native_revision" => exists ? "owned-draft-revision" : nil)
  mapping = inspection.fetch("mapping")
  mapping.merge!("synchronized_source_revision" => nil, "publicly_verified_source_revision" => nil)
  prior_proof = {"kind" => "absent", "url" => mapping.fetch("canonical_url"), "native_id" => baseline.fetch("native_id"),
    "checked_at" => "2026-10-25T18:00:00.000Z", "http_status" => 404}
  inspection.merge!("verified_native_result" => baseline, "verification" => prior_proof)
  unless restored
    inspection.merge!("native_result" => baseline, "prepared_transaction" => nil)
  end
  observation.merge!("profile" => DiscussionBridge::CmsAttentionEvidence::PROFILES.fetch(profile),
    "native_state" => restored ? "restored_baseline" : "baseline", "object_exists" => exists,
    "native_id" => baseline.fetch("native_id"), "native_revision" => baseline.fetch("native_revision"),
    "native_result" => baseline, "source_revision" => nil, "managed_content_sha256" => exists ? "c" * 64 : nil,
    "baseline_sha256" => "b" * 64, "current_sha256" => "b" * 64,
    "verification" => prior_proof.merge("checked_at" => "2026-10-25T22:00:00.000Z"),
    "prepared_transaction_id" => restored ? inspection.fetch("prepared_transaction").fetch("transaction_id") : nil)
  # Retained ownership belongs to the actual old publication. Its precise hash
  # remains the one bound by the receiver's exact verified withdrawal result.
  observation.fetch("ownership")["source_revision"] = "actual-retained-published-revision"
  {"inspection" => inspection, "observation" => observation, "profile" => profile}
end

def evaluate_withdrawn(item)
  DiscussionBridge::CmsProtocol.validate!("AttentionInspection", item.fetch("inspection"))
  DiscussionBridge::CmsProtocol.validate!("AttentionObservation", item.fetch("observation"))
  DiscussionBridge::CmsAttentionEvidence.evaluate(item.fetch("inspection"), item.fetch("observation"),
    profile: item.fetch("profile"), publication_kind: item.fetch("publication_kind", "static"))
end
[false, true].each do |restored|
  [false, true].each do |exists|
    run("qualified #{exists ? 'Astro draft' : 'Hugo absent manifest'} #{restored ? 'restored' : 'unchanged'} verified withdrawn baseline is ready") do
      item = withdrawn_fixture(exists: exists, restored: restored, profile: exists ? "astro" : "hugo")
      before = Marshal.dump(item)
    assert(evaluate_withdrawn(item).fetch("status") == "ready", "exact owned withdrawn baseline refused")
    assert(Marshal.dump(item) == before, "readiness mutated retained evidence")
      assert(item.fetch("observation").fetch("ownership").fetch("source_revision") == "actual-retained-published-revision", "receipt source revision fabricated")
    end
  end
end
{
  "missing retained prior verified withdrawal" => ->(i,o) { i["verified_native_result"] = nil },
  "missing prior verified absence proof" => ->(i,o) { i["verification"] = nil },
  "missing fresh public absence read" => ->(i,o) { o["verification"] = nil },
  "unrelated fresh absence URL" => ->(i,o) { o["verification"] = o.fetch("verification").merge("url" => "https://astro.example/unrelated/") },
  "unrelated native ID" => ->(i,o) { o["native_id"] = "foreign"; o["ownership"] = nil; o["native_result"] = nil; o["verification"] = nil },
  "missing native ownership readback" => ->(i,o) { o["ownership"] = nil },
  "receipt differs from exact verified baseline" => ->(i,o) { o.fetch("ownership")["ownership_receipt_sha256"] = "d" * 64 },
  "missing journal" => ->(i,o) { o["journal_sha256"] = nil },
  "missing owned manifest baseline" => ->(i,o) { o["baseline_sha256"] = nil },
  "foreign file/edit after admission evidence" => ->(i,o) { o["current_sha256"] = "d" * 64 },
  "uncertain operation after evidence" => ->(i,o) { o["pending_mutation"] = "uncertain" },
  "active native command" => ->(i,o) { o["native_command"] = "active" },
  "unknown native command" => ->(i,o) { o["native_command"] = "uncertain" },
  "unknown object inventory" => ->(i,o) { o["object_exists"] = nil },
  "applied static candidate is separate" => ->(i,o) { o["native_state"] = "candidate_applied" },
}.each do |name, change|
  run("404/flag is insufficient: #{name}") do
    item = withdrawn_fixture
    change.call(item.fetch("inspection"), item.fetch("observation"))
    assert(evaluate_withdrawn(item).fetch("status") != "ready", "unsafe absence admitted: #{name}")
  end
end
run("retained owned draft still requires real native revision and managed content readback") do
  %w[native_revision managed_content_sha256].each do |field|
    item = withdrawn_fixture(exists: true, profile: "astro")
    item.fetch("observation")[field] = nil
    assert(evaluate_withdrawn(item).fetch("status") != "ready", "draft lacked #{field} but was ready")
  end
end
run("forged Astro all-absent tuple is not a qualified owned draft") do
  item = withdrawn_fixture(exists: false, profile: "astro")
  assert(evaluate_withdrawn(item).fetch("status") != "ready", "deleted known Astro object admitted")
end
run("prior verified withdrawal must match its exact prior proof URL/native identity") do
  item = withdrawn_fixture
  item.fetch("inspection")["verification"]["url"] = "https://hugo.example/unrelated/"
  assert(evaluate_withdrawn(item).fetch("status") != "ready", "unrelated prior proof accepted")
end
%w[ghost wordpress statamic_flat statamic_db].each do |profile|
  run("#{profile} retains exact verified-withdrawn receipt source revision without requiring current public proof") do
    item = withdrawn_fixture(exists: true, profile: profile)
    item["publication_kind"] = "dynamic"
    item.fetch("observation")["verification"] = nil
    assert(evaluate_withdrawn(item).fetch("status") == "ready", "dynamic exact known withdrawal refused")
    item.fetch("observation")["verification"] = item.fetch("inspection").fetch("verification").merge("url" => "https://astro.example/foreign/")
    assert(evaluate_withdrawn(item).fetch("status") != "ready", "provided foreign dynamic proof ignored")
  end
end
def candidate_after_withdrawal
  item = withdrawn_fixture(exists: true, profile: "ghost")
  item["publication_kind"] = "dynamic"
  inspection, observation = item.values_at("inspection", "observation")
  candidate = FIXTURES.fetch("restored").fetch("inspection").fetch("native_result").deep_dup
  candidate.merge!("native_id" => inspection.fetch("mapping").fetch("destination_native_id"),
    "native_revision" => "actual-current-candidate-revision",
    "ownership_receipt_sha256" => inspection.fetch("verified_native_result").fetch("ownership_receipt_sha256"))
  observation.merge!("native_state" => "candidate_applied", "native_result" => candidate,
    "native_revision" => candidate.fetch("native_revision"), "source_revision" => inspection.fetch("work").fetch("source_revision"),
    "candidate_sha256" => "c" * 64, "current_sha256" => "c" * 64, "verification" => nil)
  item
end
run("known dynamic candidate after verified withdrawal binds exact retained old receipt, never generic old source revision") do
  item = candidate_after_withdrawal
  assert(evaluate_withdrawn(item).fetch("status") == "ready", "proven current candidate with exact retained withdrawal receipt refused")
end
{
  "no prior verified withdrawal" => ->(i,o) { i["verified_native_result"] = nil },
  "prior result is publication instead of withdrawal" => ->(i,o) { i["verified_native_result"] = FIXTURES.fetch("restored").fetch("inspection").fetch("native_result").deep_dup },
  "missing prior exact absence proof" => ->(i,o) { i["verification"] = nil },
  "unrelated prior absence URL" => ->(i,o) { i.fetch("verification")["url"] = "https://ghost.example/unrelated/" },
  "different current receipt despite internally matching candidate" => ->(i,o) { o.fetch("ownership")["ownership_receipt_sha256"] = "d" * 64; o.fetch("native_result")["ownership_receipt_sha256"] = "d" * 64 },
  "candidate content/source hash differs" => ->(i,o) { o.fetch("native_result").fetch("representation")["source_content_sha256"] = "d" * 64 },
  "candidate manifest differs from expected" => ->(i,o) { o["current_sha256"] = "d" * 64 },
  "candidate native outcome remains uncertain" => ->(i,o) { o["pending_mutation"] = "uncertain" },
}.each do |name, change|
  run("known candidate after withdrawal refuses #{name}") do
    item = candidate_after_withdrawal
    change.call(item.fetch("inspection"), item.fetch("observation"))
    assert(evaluate_withdrawn(item).fetch("status") != "ready", "unproven candidate receipt admitted: #{name}")
  end
end
actual = JSON.parse(File.read(File.join(ROOT, "spec/fixtures/attention-withdrawn-collectors.json")))
actual.fetch("cases").each do |item|
  run("actual synthetic collector output: #{item.fetch('id')}") do
    outcome = evaluate_withdrawn(item)
    assert(outcome.fetch("status") == item.fetch("expected_status"), "collector/Core status mismatch: #{outcome.inspect}")
  end
end
puts JSON.pretty_generate(checks: CHECKS.length, passed: CHECKS, failures: FAILURES, runtime: RUBY_DESCRIPTION,
  boundary: "Actual typed CmsAttentionEvidence using controlled known-withdrawn baseline fixtures; no native writer/public HTTP proof performed. Separate root interop runs use actual Hugo/Astro synthetic collector outputs. Cross-host clocks are audit fields; no invented TTL/freshness timestamp policy.")
exit(FAILURES.empty? ? 0 : 1)
