# frozen_string_literal: true

# Actual production diagnostic projection and early required-output guards with
# stdlib logger only. HTML5/Core, native log durability and DB UNEXECUTED.
require "json"
require "logger"
require "stringio"
require_relative "../../lib/discussion_bridge/portable_content"
require_relative "../../lib/discussion_bridge/native_content_preservation"
require_relative "../../lib/discussion_bridge/cms_record_store"

checks = 0
assert = ->(value, message) { raise(message) unless value; checks += 1 }
output = StringIO.new
logger = Logger.new(output)
logger.formatter = ->(_severity, _time, _program, message) { "#{message}\n" }
connection = Struct.new(:public_id).new("11111111-1111-4111-8111-111111111111")
store = DiscussionBridge::CmsRecordStore.new(connection)
losses = [{ "kind" => "script_nonempty_data_removed_or_changed", "element" => "script", "attribute" => nil, "count" => 1 }]
error = DiscussionBridge::NativeContentPreservation::Loss.new(losses)
input = {
  "mutation_id" => "22222222-2222-4222-8222-222222222222", "secret" => "SECRET_SENTINEL",
  "bridge_record" => {
    "external_id" => "article-one", "source_revision" => "prepared:r1", "correlation_id" => "33333333-3333-4333-8333-333333333333",
    "content_html" => '<script>PROGRAM_SENTINEL()</script><script type="application/json">DATA_SENTINEL</script>',
    "canonical_url" => "https://user:CREDENTIAL_SENTINEL@source.example/article/", "title" => "TITLE_SENTINEL",
  },
}
rows = -> { output.string.lines.map { |line| JSON.parse(line) } }
store.send(:report_content_loss!, input, error, logger: logger)
row = rows.call.last
assert.call(row.keys.sort == %w[event connection_id external_id source_revision correlation_id mutation_id diagnostic_kind losses].sort, "Unexpected diagnostic projection")
assert.call(row.values_at("connection_id", "external_id", "source_revision", "correlation_id", "mutation_id") ==
  [connection.public_id, "article-one", "prepared:r1", input.fetch("bridge_record").fetch("correlation_id"), input.fetch("mutation_id")], "Incorrect scoped IDs")
assert.call(row.fetch("losses") == losses && row.fetch("diagnostic_kind") == "observed_content_loss", "Incorrect observed-loss distinction")
assert.call(!output.string.match?(/SECRET_SENTINEL|PROGRAM_SENTINEL|DATA_SENTINEL|CREDENTIAL_SENTINEL|TITLE_SENTINEL|content_html|canonical_url|https:/), "Diagnostic leaked source/credential material")

preparation = DiscussionBridge::PortableContent::PreparationUnavailable.new("UNSAFE_ERROR_BODY_SENTINEL", diagnostic_code: "css_reference_unsupported")
store.send(:report_content_loss!, input, preparation, logger: logger)
assert.call(rows.call.last.fetch("diagnostic_kind") == "article_unavailable" && rows.call.last.fetch("losses").first.fetch("kind") == "css_reference_unsupported", "Preparation limitation misclassified")
assert.call(!output.string.include?("UNSAFE_ERROR_BODY_SENTINEL"), "Exception body leaked")
before = output.string.dup
store.send(:report_content_loss!, input, StandardError.new("UNSAFE_OTHER_ERROR"), logger: logger)
assert.call(output.string == before, "Unrelated exception relabeled/logged")

[nil, false, "", "\xFF".b].each do |unavailable|
  begin
    DiscussionBridge::NativeContentPreservation.verify!(source_html: "Unformatted text is valid", cooked_html: unavailable,
      source_url: "https://source.example/article/", native_url: "https://forum.example/t/topic/1")
    raise "Unavailable required native evidence accepted"
  rescue DiscussionBridge::NativeContentPreservation::ArticleUnavailable => failure
    assert.call(failure.diagnostic_kind == "article_unavailable" && failure.losses.first.fetch("kind") == "required_native_article_unavailable", "Required output confused with observed loss")
    store.send(:report_content_loss!, input, failure, logger: logger)
  end
end

store.send(:log_content_loss!, error, external_id: "article-move", source_revision: "prepared:r2",
  mutation_id: "44444444-4444-4444-8444-444444444444", resource_id: "55555555-5555-4555-8555-555555555555", logger: logger)
last = rows.call.last
assert.call(last.values_at("external_id", "source_revision", "mutation_id", "correlation_id", "resource_id") ==
  ["article-move", "prepared:r2", "44444444-4444-4444-8444-444444444444", nil, "55555555-5555-4555-8555-555555555555"], "Move IDs/correlation fabricated or mixed")
assert.call(rows.call.first == row && last.fetch("diagnostic_kind") == "observed_content_loss", "Item contexts mixed")
assert.call(!output.string.match?(/SENTINEL|UNSAFE_OTHER_ERROR/), "Unsafe material reached later diagnostic")
puts JSON.generate(checks: checks, result: "passed", limits: "actual early native-output guards/diagnostic projection + stdlib logger only; HTML5/Core/native log durability/transactions UNEXECUTED")
