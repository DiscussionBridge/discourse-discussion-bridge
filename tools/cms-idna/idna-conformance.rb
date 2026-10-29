# frozen_string_literal: true

# Dependency qualification only: exercise the exact packaged private closure.
# The corpus is an explicit, locally staged Unicode17 input; never fetched here.
require "json"
require File.expand_path(
          "../../lib/discussion_bridge/cms_url_authority",
          __dir__
        )

options = {
  use_std3_ascii_rules: false,
  check_hyphens: false,
  check_bidi: true,
  check_joiners: true,
  transitional_processing: false,
  verify_dns_length: false,
  ignore_invalid_punycode: false
}.freeze

decode =
  lambda do |text|
    next "" if text == '""'
    text.gsub(/\\x\{([0-9a-fA-F]+)\}|\\u([0-9a-fA-F]{4})/) do
      [($1 || $2).to_i(16)].pack("U")
    end
  end

unless Digest::SHA256.file(ARGV.fetch(0)).hexdigest ==
         "beb5d0be20e896189b03209a82fdc34f06351502bbd4b8e2523583fc2954d9cf"
  abort "Wrong official IDNA corpus"
end
counts = Hash.new(0)
mismatches = []
File
  .foreach(ARGV.fetch(0), encoding: "UTF-8")
  .with_index(1) do |line, number|
    content = line.split("#", 2).first.to_s.strip
    next if content.empty?

    fields = content.split(";", -1).map(&:strip)
    source = decode.call(fields.fetch(0))
    unicode = fields.fetch(1).empty? ? source : decode.call(fields[1])
    unicode_errors = fields.fetch(2).scan(/[A-Z][0-9](?:_[0-9])?/)
    ascii = fields.fetch(3).empty? ? unicode : decode.call(fields[3])
    errors =
      (
        if fields.fetch(4).empty?
          unicode_errors
        else
          fields[4].scan(/[A-Z][0-9](?:_[0-9])?/)
        end
      )
    relevant_errors = errors - %w[A4_1 A4_2 V2 V3 U1]

    actual = nil
    error = nil
    crashed = false
    begin
      actual = DiscussionBridge::CmsIdnaVendor.to_ascii(source, **options)
    rescue DiscussionBridge::CmsIdnaVendor::Error,
           ArgumentError,
           EncodingError,
           RegexpError => failure
      error = failure.class.name + ": " + failure.message
      crashed = failure.is_a?(RegexpError)
    end
    ok = relevant_errors.empty? ? (error.nil? && actual == ascii) : !error.nil?
    ok = false if crashed
    counts[ok ? :passed : :failed] += 1
    if !ok && mismatches.length < 40
      mismatches << {
        line: number,
        source: source.dump,
        expected: ascii.dump,
        statuses: errors,
        relevant: relevant_errors,
        actual: actual&.dump,
        error: error&.scrub
      }
    end
  end

puts JSON.pretty_generate(
       ruby: RUBY_VERSION,
       native_unicode: RbConfig::CONFIG["UNICODE_VERSION"],
       counts: counts,
       mismatches: mismatches
     )
exit(counts[:failed].zero? ? 0 : 1)
