# frozen_string_literal: true

# Portable value/dependency checks only: not Rails, URL ownership, network-origin
# equivalence, installed-state or review evidence. Explicit fixture arguments
# support a declared unfrozen development pairing without a private path.
require "digest"
require "json"
root = File.expand_path("../..", __dir__)
fixtures = ARGV[0] || File.join(root, "spec/fixtures/v4/url-domain-policy.json")
schema =
  ARGV[1] || File.join(root, "lib/discussion_bridge/cms_protocol_types.json")
fixture_sha = Digest::SHA256.file(fixtures).hexdigest
schema_sha = Digest::SHA256.file(schema).hexdigest
vectors = JSON.parse(File.binread(fixtures))
policy =
  JSON
    .parse(File.binread(schema))
    .fetch("types")
    .fetch("Url")
    .fetch("domain_policy")
unless vectors.fetch("policy_id") == policy.fetch("id") &&
         vectors.fetch("unicode_version") == policy.fetch("unicode_version")
  raise "URL fixture policy mismatch"
end
native_sample = "a\u0315\u0300\u05AE\u1ACFb"
native_before = native_sample.unicode_normalize(:nfc)
native_method = String.instance_method(:unicode_normalize)
ambient_idna = defined?(::URI::IDNA)
require File.join(root, "lib/discussion_bridge/cms_url_authority")
unless native_before == native_sample.unicode_normalize(:nfc) &&
         native_method == String.instance_method(:unicode_normalize)
  raise "Global normalizer changed"
end
unless ambient_idna == defined?(::URI::IDNA)
  raise "Ambient IDNA namespace changed"
end
checks = 2
results = {}
vectors
  .fetch("cases")
  .each do |item|
    input = item.fetch("url").dup
    original = input.b.dup
    begin
      parsed = DiscussionBridge::CmsUrlAuthority.parse(input, policy: policy)
      raise "Accepted #{item.fetch("id")}" unless item.fetch("accepted")
      unless parsed.facts == item.fetch("facts")
        raise "Wrong facts #{item.fetch("id")}"
      end
      results[item.fetch("id")] = parsed
      checks += 1
    rescue DiscussionBridge::CmsUrlAuthority::Invalid
      raise "Rejected #{item.fetch("id")}" if item.fetch("accepted")
      checks += 1
    end
    raise "Input mutated #{item.fetch("id")}" unless input.b == original
    checks += 1
  end
vectors
  .fetch("comparisonPairs")
  .each do |pair|
    left = results.fetch(pair.fetch("left"))
    right = results.fetch(pair.fetch("right"))
    unless (left.ascii_host == right.ascii_host) == pair.fetch("asciiHostEqual")
      raise "Wrong host comparison #{pair.fetch("id")}"
    end
    unless (left.effective_port == right.effective_port) ==
             pair.fetch("effectivePortEqual")
      raise "Wrong port comparison #{pair.fetch("id")}"
    end
    a =
      vectors
        .fetch("cases")
        .find { |item| item.fetch("id") == pair.fetch("left") }
        .fetch("url")
    b =
      vectors
        .fetch("cases")
        .find { |item| item.fetch("id") == pair.fetch("right") }
        .fetch("url")
    unless (a.b == b.b) == pair.fetch("originalBytesEqual")
      raise "Wrong original comparison #{pair.fetch("id")}"
    end
    checks += 3
  end
vectors
  .fetch("legacyAsciiKeys")
  .each do |item|
    parts =
      DiscussionBridge::CmsUrlAuthority.parse(item.fetch("url"), policy: policy)
    unless parts.legacy_key == item.fetch("expected")
      raise "Legacy key changed #{item.fetch("id")}"
    end
    checks += 1
  end
unless Digest::SHA256.file(fixtures).hexdigest == fixture_sha
  raise "Fixture changed during run"
end
unless Digest::SHA256.file(schema).hexdigest == schema_sha
  raise "Schema changed during run"
end
puts JSON.generate(
       checks: checks,
       fixture_sha256: fixture_sha,
       policy_source_sha256: schema_sha,
       limitations:
         "Value/dependency checks only; no native origin/collision/record/receipt/installed acceptance"
     )
