# frozen_string_literal: true

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
unless Digest::SHA256.file(ARGV.fetch(0)).hexdigest ==
         "5019ffd530751a741900c849c0e010332f142a3612234639bd200b82138a87db"
  abort "Wrong official normalization corpus"
end
counts = Hash.new(0)
examples = []
File
  .foreach(ARGV.fetch(0), encoding: "UTF-8")
  .with_index(1) do |line, number|
    content = line.split("#", 2).first.to_s.strip
    next if content.empty? || content.start_with?("@")
    fields =
      content
        .split(";")
        .first(5)
        .map { |field| field.split.map { |point| point.to_i(16) }.pack("U*") }
    source, expected, nfd, nfkc, nfkd = fields
    counts[:vectors] += 1
    if defined?(DiscussionBridge::CmsIdnaNfc17)
      [
        [source, expected],
        [expected, expected],
        [nfd, expected],
        [nfkc, nfkc],
        [nfkd, nfkc]
      ].each do |input, output|
        counts[:private_nfc_checks] += 1
        counts[
          :private_nfc_mismatches
        ] += 1 unless DiscussionBridge::CmsIdnaNfc17.normalize(input, :nfc) ==
          output
        counts[:private_normalized_checks] += 1
        counts[
          :private_normalized_mismatches
        ] += 1 unless DiscussionBridge::CmsIdnaNfc17.normalized?(input, :nfc) ==
          (input == output)
      end
      {
        nfd: [nfd, nfd, nfd, nfkd, nfkd],
        nfkc: [nfkc] * 5,
        nfkd: [nfkd] * 5
      }.each do |form, outputs|
        fields
          .zip(outputs)
          .each do |input, output|
            counts[:private_other_form_checks] += 1
            counts[
              :private_other_form_mismatches
            ] += 1 unless DiscussionBridge::CmsIdnaNfc17.normalize(
              input,
              form
            ) == output
          end
      end
    end
    next if source.unicode_normalize(:nfc) == expected
    counts[:native_nfc_mismatches] += 1
    begin
      actual_domain =
        DiscussionBridge::CmsIdnaVendor.to_ascii(
          "x-#{source}.example",
          **options
        )
      expected_domain =
        DiscussionBridge::CmsIdnaVendor.to_ascii(
          "x-#{expected}.example",
          **options
        )
      next if actual_domain == expected_domain
      # Exploratory only: UTS46 mapping precedes NFC, so pre-normalizing source
      # is not a normative domain oracle for all mapped characters (e.g. U+0345).
      counts[:nfc_preprocessed_domain_differences] += 1
      if examples.length < 12
        examples << {
          line: number,
          source: source.dump,
          expected_nfc: expected.dump,
          actual_domain: actual_domain,
          expected_domain: expected_domain
        }
      end
    rescue DiscussionBridge::CmsIdnaVendor::Error, ArgumentError, EncodingError
      counts[:not_accepted_as_domain] += 1
    end
  end
puts JSON.pretty_generate(
       ruby: RUBY_VERSION,
       native_unicode: RbConfig::CONFIG["UNICODE_VERSION"],
       counts: counts,
       examples: examples
     )
exit(
  (
    if counts[:private_nfc_mismatches].zero? &&
         counts[:private_normalized_mismatches].zero? &&
         counts[:private_other_form_mismatches].zero?
      0
    else
      1
    end
  )
)
