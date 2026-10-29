# frozen_string_literal: true

# Actual CmsSourceMoveStore#finalize, protocol, projection, identity and proof
# checks. Auth/current native baseline, persistence and rendering are explicit
# in-memory seams. A sentinel stops at the first URL write boundary: reaching it
# proves projection admission, never a native commit or public-proof success.
require "json"
require "digest"
require_relative "support/standalone_enumerable_helpers"

class Object
  def blank? = respond_to?(:empty?) ? empty? : !self
  def present? = blank? == false
  def presence = present? ? self : nil
end
class String
  def blank? = match?(/\A\p{Space}*\z/)
end

root = File.expand_path("../..", __dir__)
%w[cms_protocol portable_content cms_generated_excerpt cms_to_publication cms_record_store
   cms_work_coordinator cms_url_move_proof cms_source_move_store].each do |name|
  require File.join(root, "lib/discussion_bridge", name)
end

module SourceMoveProjectionChecks
  class WriteBoundaryReached < StandardError; end
  NONCE = Base64.urlsafe_encode64("n" * 32, padding: false).freeze
  Record = Struct.new(:id)
  Binding = Struct.new(:external_id, :canonical_url, :bridge_record)
  Move = Struct.new(:state, :expected_revision, :old_url, :new_url, :proof_nonce, :prepared_at, :old_ownership)
  class << self
    attr_accessor :trace
  end
end

# The real finalizer only reads revision existence before the projection guard.
# No ActiveRecord, transaction, encryption, authentication or native mutation is
# represented by these doubles; unexpected writes fail instead of succeeding.
class DiscussionBridgeCmsToSourceRevision
  def self.exists?(**) = false
  def self.create!(**) = raise("Unexpected revision persistence")
end
module DiscussionBridge
  class CmsUrlReservation
    def self.with_locks(urls)
      SourceMoveProjectionChecks.trace << ["URL_write_boundary", urls]
      raise SourceMoveProjectionChecks::WriteBoundaryReached
    end
  end
end

class SourceMoveProjectionHarness < DiscussionBridge::CmsSourceMoveStore
  def initialize(source, new_url)
    super(nil, clock: -> { Time.utc(2026, 10, 25, 16) })
    @fixture_source = source
    @fixture_receipt = {
      "revision" => source.fetch("source_revision"), "created_at" => source.fetch("source_created_at"),
      "content_sha256" => source.fetch("source_content_sha256"), "input" => source,
      "managed_native_sha256" => "f" * 64, "native_ownership_receipt_sha256" => "1" * 64,
    }
    @fixture_binding = SourceMoveProjectionChecks::Binding.new(source.fetch("external_id"),
      source.fetch("canonical_url"), SourceMoveProjectionChecks::Record.new(17))
    @fixture_move = SourceMoveProjectionChecks::Move.new("prepared", source.fetch("source_revision"),
      source.fetch("canonical_url"), new_url, SourceMoveProjectionChecks::NONCE, Time.utc(2026, 10, 25, 15, 59),
      ownership_facts(@fixture_binding, @fixture_receipt))
  end

  def retained_state = Marshal.dump([@fixture_source, @fixture_receipt, @fixture_binding, @fixture_move])

  private

  def mutation(*)
    value = yield
    SourceMoveProjectionChecks.trace << ["mutation_receipt_write"]
    value
  end

  def current_source!(_resource, expected)
    raise "Unexpected fixture predecessor" unless expected == @fixture_receipt.fetch("revision")
    [@fixture_binding, @fixture_receipt, nil]
  end

  def move!(*) = @fixture_move

  def source_move_baseline!(receipt, native)
    return super unless DiscussionBridge::CmsGeneratedExcerpt.generated?(receipt.fetch("input"))
    # Actual native segment/cooked verification requires Nokogiri/Core. This is
    # an already established matching generated baseline, not fake rendering.
    true
  end
end

protocol = DiscussionBridge::CmsProtocol
excerpt = DiscussionBridge::CmsGeneratedExcerpt
resource_id = "22222222-2222-4222-8222-222222222222"
move_id = "33333333-3333-4333-8333-333333333333"
old_url = "https://source.example/old/"
normal_url = "https://source.example/new-long-location/"
long_url = "https://source.example/" + ("segment/" * 220)
escaped_url = "https://source.example/path/" + ("a&b/" * 20)

full = lambda do |html|
  {
    "direction" => "to_discourse", "external_id" => "article", "canonical_url" => old_url,
    "title" => "Projection bounds", "content_html" => html, "published" => true,
    "source_revision" => "native:r1", "expected_source_revision" => nil,
    "source_created_at" => "2026-10-14T00:00:00.000Z", "source_updated_at" => nil,
    "representation" => { "kind" => "full" },
    "source_content_sha256" => Digest::SHA256.hexdigest(html.b), "source_content_bytes" => html.bytesize,
  }
end
generated = lambda do |article|
  # Truthful complete-source evidence, measured before selecting this excerpt.
  complete = article + "<p>" + ("z" * 50_000) + "</p>"
  source = full.call(complete)
  measured = protocol.semantic_identity("mutation_id" => excerpt::MEASUREMENT_ID, "bridge_record" => source).bytesize
  source.merge("content_html" => article + excerpt.link(old_url), "representation" => {
    "kind" => "generated_excerpt", "read_more_url" => old_url,
    "article_content_bytes" => article.bytesize, "article_content_sha256" => Digest::SHA256.hexdigest(article.b),
    "selection_source_revision" => "native:r1", "selection_full_request_bytes" => measured,
  })
end
build = ->(kind, article) { kind == "full" ? full.call(article) : generated.call(article) }

# Fixture construction only. Tests execute the real finalizer and real guard;
# this expected tree is used to measure an exact external contract boundary.
expected_projection = lambda do |source, url|
  value = source.merge("canonical_url" => url, "source_revision" => "native:r2",
    "expected_source_revision" => "native:r1", "source_updated_at" => nil)
  if source.fetch("representation").fetch("kind") == "generated_excerpt"
    value = value.merge("content_html" => excerpt.article(source) + excerpt.link(url),
      "representation" => source.fetch("representation").merge("read_more_url" => url))
  end
  value
end
envelope_bytes = ->(source) { protocol.semantic_identity("mutation_id" => excerpt::MEASUREMENT_ID, "bridge_record" => source).bytesize }
fit_envelope = lambda do |kind, target, url|
  article = "<p>" + ('"' * 28_000) + "</p>"
  source = build.call(kind, article)
  padding = target - envelope_bytes.call(expected_projection.call(source, url))
  raise "Fixture already exceeds requested boundary" if padding.negative?
  source = build.call(kind, article.sub("</p>", ("x" * padding) + "</p>"))
  raise "Fixture does not measure exact envelope" unless envelope_bytes.call(expected_projection.call(source, url)) == target
  excerpt.validate_envelope!(source)
  source
end
fit_html = lambda do |kind, target, url|
  suffix = kind == "generated_excerpt" ? excerpt.link(url).bytesize : 0
  source = build.call(kind, "<p>" + ("x" * (target - suffix - 7)) + "</p>")
  raise "Fixture does not measure exact HTML" unless expected_projection.call(source, url).fetch("content_html").bytesize == target
  # Full one-over HTML is an explicitly corrupted retained-state fixture; a
  # valid full edition cannot grow HTML on a URL-only move. Generated grows.
  excerpt.validate_envelope!(source) unless kind == "full" && target > 49_152
  source
end

cases = []
%w[full generated_excerpt].each do |kind|
  cases << ["#{kind}: ordinary projection admitted", build.call(kind, "<p>Retained article</p>"), normal_url, nil]
  cases << ["#{kind}: envelope exactly 65536 admitted", fit_envelope.call(kind, 65_536, normal_url), normal_url, nil]
  cases << ["#{kind}: envelope 65537 refused", fit_envelope.call(kind, 65_537, normal_url), normal_url, "body_too_large"]
  cases << ["#{kind}: long URL exact envelope admitted", fit_envelope.call(kind, 65_536, long_url), long_url, nil]
  cases << ["#{kind}: long URL one-over refused", fit_envelope.call(kind, 65_537, long_url), long_url, "body_too_large"]
  cases << ["#{kind}: escaped URL exact envelope admitted", fit_envelope.call(kind, 65_536, escaped_url), escaped_url, nil]
  cases << ["#{kind}: escaped URL one-over refused", fit_envelope.call(kind, 65_537, escaped_url), escaped_url, "body_too_large"]
  cases << ["#{kind}: HTML exactly 49152 admitted", fit_html.call(kind, 49_152, normal_url), normal_url, nil]
  cases << ["#{kind}: HTML 49153 refused", fit_html.call(kind, 49_153, normal_url), normal_url, "body_too_large"]
end
corrupt = full.call("<p>Retained article</p>").merge("source_content_sha256" => "0" * 64)
cases << ["full: corrupted retained hash refused by whole-record validation", corrupt, normal_url, "content_hash_mismatch"]

rows = cases.map do |name, source, url, expected_error|
  SourceMoveProjectionChecks.trace = []
  harness = SourceMoveProjectionHarness.new(source, url)
  before = harness.retained_state
  input = {
    "mutation_id" => excerpt::MEASUREMENT_ID, "move_id" => move_id, "proof_nonce" => SourceMoveProjectionChecks::NONCE,
    "expected_source_revision" => "native:r1", "new_source_revision" => "native:r2", "source_updated_at" => nil,
    "verification" => { "url" => url, "external_id" => "article", "source_revision" => "native:r2",
      "source_content_sha256" => source.fetch("source_content_sha256"),
      "native_ownership_receipt_sha256" => "1" * 64, "native_publication_sha256" => "2" * 64,
      "verification_profile" => "projection-boundary-fixture", "checked_at" => "2026-10-25T16:00:00.000Z" },
  }
  actual = nil
  begin
    harness.finalize(resource_id, move_id, input)
    actual = "unexpected_return"
  rescue SourceMoveProjectionChecks::WriteBoundaryReached
    actual = "write_boundary_reached"
  rescue DiscussionBridge::CmsProtocol::Error => error
    actual = error.code
  rescue StandardError => error
    actual = "#{error.class}: #{error.message}"
  end
  expected = expected_error || "write_boundary_reached"
  unchanged = harness.retained_state == before
  no_writes = expected_error ? SourceMoveProjectionChecks.trace.empty? : SourceMoveProjectionChecks.trace.size == 1
  passed = actual == expected && unchanged && no_writes
  projected = expected_projection.call(source, url)
  row = { name: name, status: passed ? "passed" : "failed", expected: expected, actual: actual,
    projected_html_bytes: projected.fetch("content_html").bytesize, projected_envelope_bytes: envelope_bytes.call(projected),
    retained_state_unchanged: unchanged, trace: SourceMoveProjectionChecks.trace }
  puts JSON.generate(row)
  row
end
failed = rows.count { |row| row.fetch(:status) == "failed" }
puts JSON.generate(tests: rows.size, passed: rows.size - failed, failed: failed,
  implementation: "actual CmsSourceMoveStore#finalize and production protocol/projection/identity/proof methods",
  seams: "Current native/auth baseline and persistence are in-memory; successful admission deliberately stops at the first URL write boundary. No Native/DB/Core/public-proof acceptance.")
exit(failed.zero? ? 0 : 1)
