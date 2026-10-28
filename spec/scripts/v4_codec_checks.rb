# frozen_string_literal: true

# Value-local author checks only. These compatibility helpers provide ordinary
# framework convenience methods; no Rails/database/native proof is exercised.
require "json"
require "digest"
class Object
  def blank? = respond_to?(:empty?) ? empty? : !self
  def present? = !blank?
  def presence = present? ? self : nil
end
class String
  def blank? = match?(/\A\p{Space}*\z/)
end
class Hash
  def except(*keys) = reject { |key, _| keys.include?(key) }
end
root = File.expand_path("../..", __dir__)
require File.join(root, "lib/discussion_bridge/cms_protocol")
require File.join(root, "lib/discussion_bridge/managed_native_publication")
require File.join(root, "lib/discussion_bridge/cms_to_publication")
require File.join(root, "lib/discussion_bridge/cms_generated_excerpt")
contract = File.expand_path("../adapter-contract", root)
positive = JSON.parse(File.read(File.join(contract, "fixtures/positive-examples.json"))).fetch("fixtures")
negative = JSON.parse(File.read(File.join(contract, "fixtures/rejection-cases.json")))
checks = 0
positive.each do |item|
  DiscussionBridge::CmsProtocol.validate!(item.fetch("type"), item.fetch("value"))
  checks += 1
end
negative.fetch("type_cases").each do |item|
  next unless DiscussionBridge::CmsProtocol::SCHEMA.fetch("types").key?(item.fetch("type"))
  begin
    DiscussionBridge::CmsProtocol.validate!(item.fetch("type"), item.fetch("input"))
    raise "Expected rejected shape #{item.fetch('id')}"
  rescue DiscussionBridge::CmsProtocol::Error => error
    raise "Wrong code for #{item.fetch('id')}: #{error.code}" unless error.code == item.fetch("expected").fetch("code")
  end
  checks += 1
end
negative.fetch("raw_json_cases").each do |item|
  begin
    DiscussionBridge::CmsProtocol.parse_json(item.fetch("raw"))
    raise "Expected rejected JSON #{item.fetch('id')}"
  rescue DiscussionBridge::CmsProtocol::Error => error
    raise "Wrong raw code #{item.fetch('id')}: #{error.code}" unless error.code == item.fetch("expected").fetch("code")
  end
  checks += 1
end
preservation_error = {
  "outcome" => "rejected", "code" => "content_preservation_unavailable",
  "retryable" => false, "retry_after_seconds" => nil,
  "correlation_id" => nil, "core_fallback" => false
}
DiscussionBridge::CmsProtocol::SCHEMA.fetch("routes").each do |route|
  id = route.fetch("id")
  allowed = %w[V4-02 V4-29].include?(id)
  begin
    DiscussionBridge::CmsProtocol.validate_error_response!(id, preservation_error, 422)
    raise "Preservation error outside02/29 #{id}" unless allowed
  rescue DiscussionBridge::CmsProtocol::Error => error
    raise "Wrong route error #{id}: #{error.code}" if allowed || error.code != "invalid_field"
  end
  checks += 1
end
bad_preservation = [
  [preservation_error.merge("retryable" => true), 422],
  [preservation_error.merge("retry_after_seconds" => 1), 422],
  [preservation_error, 503],
  [preservation_error.merge("detail" => "not a public field"), 422]
]
bad_preservation.each do |value, status|
  begin
    DiscussionBridge::CmsProtocol.validate_error_response!("V4-02", value, status)
    raise "Accepted invalid preservation Error"
  rescue DiscussionBridge::CmsProtocol::Error
    checks += 1
  end
end
%w[Failure Work].each do |type|
  fixture = if type == "Work"
    positive.find { |item| item.fetch("type") == "Lease" }.fetch("value").fetch("work")
  else
    positive.find { |item| item.fetch("type") == type }.fetch("value")
  end
  value = Marshal.load(Marshal.dump(fixture))
  value[type == "Failure" ? "code" : "last_failure_code"] = "content_preservation_unavailable"
  value["retry_after_seconds"] = nil if type == "Failure"
  begin
    DiscussionBridge::CmsProtocol.validate!(type, value)
    raise "Accepted preservation error in From #{type}"
  rescue DiscussionBridge::CmsProtocol::Error => error
    raise "Wrong From exclusion error" unless error.code == "invalid_field"
  end
  checks += 1
  if type == "Work"
    lease = Marshal.load(Marshal.dump(positive.find { |item| item.fetch("type") == "Lease" }.fetch("value")))
    lease["work"]["last_failure_code"] = "content_preservation_unavailable"
    begin
      DiscussionBridge::CmsProtocol.validate!("Lease", lease)
      raise "Accepted nested preservation error in From Work"
    rescue DiscussionBridge::CmsProtocol::Error => error
      raise "Wrong nested From error" unless error.code == "invalid_field"
    end
    checks += 1
  end
end
record = Marshal.load(Marshal.dump(positive.find { |item| item.fetch("type") == "ToResolve" }.fetch("value").fetch("bridge_record")))
complete = '<p>' + ('"' * 40_000) + '</p>'
record["content_html"] = complete
record["representation"] = { "kind" => "full" }
record["source_content_bytes"] = complete.bytesize
record["source_content_sha256"] = Digest::SHA256.hexdigest(complete)
full_envelope = DiscussionBridge::CmsProtocol.semantic_identity({ "mutation_id" => "11111111-1111-4111-8111-111111111111", "bridge_record" => record }).bytesize
raise "Envelope-only case missing" unless complete.bytesize <= 49_152 && full_envelope > 65_536
article = '<p>Preserved source article prefix.</p>'
record["content_html"] = article + DiscussionBridge::CmsGeneratedExcerpt.link(record.fetch("canonical_url"))
record["representation"] = {
  "kind" => "generated_excerpt", "read_more_url" => record.fetch("canonical_url"),
  "article_content_bytes" => article.bytesize, "article_content_sha256" => Digest::SHA256.hexdigest(article),
  "selection_source_revision" => record.fetch("source_revision"), "selection_full_request_bytes" => full_envelope,
}
DiscussionBridge::CmsGeneratedExcerpt.validate_selection!(record)
checks += 1
moved = DiscussionBridge::CmsGeneratedExcerpt.project_move(record, 'https://source.example/new-location/', 'new-native-revision', nil)
DiscussionBridge::CmsGeneratedExcerpt.validate_selection!(moved, moved)
raise "Article changed" unless moved.fetch("content_html").start_with?(article)
raise "Complete source fact changed" unless %w[source_content_bytes source_content_sha256].all? { |key| moved[key] == record[key] }
raise "Selection history changed" unless moved.fetch("representation").fetch("selection_source_revision") == record.fetch("source_revision")
checks += 1
puts JSON.generate({ checks: checks, positive_shapes: positive.length, full_source_bytes: complete.bytesize,
                     full_request_bytes: full_envelope, source_identity: DiscussionBridge::CmsToPublication.identity(record),
                     moved_identity: DiscussionBridge::CmsToPublication.identity(moved), record: record, moved: moved,
                     limits: "typed/value helpers only; no Rails/HTML5/native/database/public-proof execution" })
