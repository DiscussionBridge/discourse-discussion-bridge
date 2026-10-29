# frozen_string_literal: true

# Explicit, offline dependency refresh. Normal packaging uses committed members;
# neither customer installation nor CI silently downloads or changes the bundle.
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

unless ARGV.length == 5
  abort "usage: ruby vendor.rb URI_IDNA_SOURCE UCD17 RUBY33_SOURCE RUBY_CURRENT_SOURCE NEW_OUTPUT"
end
upstream, data_dir, ruby_old, ruby_current, output =
  ARGV.map { |path| File.expand_path(path) }
abort "Output must be a new directory" if File.exist?(output)
expected_commit = "29fadb2b73599c66db3202d62ceb1d25eefeca12"
# Read-only, command-local CRLF normalization matches the declared LF copy
# below on both Windows and Linux. It does not alter Git/user configuration.
git = [
  "git",
  "-c",
  "safe.directory=#{upstream}",
  "-c",
  "core.autocrlf=true",
  "-C",
  upstream
]
identity, status =
  Open3.capture2e({ "GIT_OPTIONAL_LOCKS" => "0" }, *git, "rev-parse", "HEAD")
unless status.success? && identity.strip == expected_commit
  abort "uri-idna source identity mismatch"
end
changes, status =
  Open3.capture2e(
    { "GIT_OPTIONAL_LOCKS" => "0" },
    *git,
    "status",
    "--porcelain",
    "--untracked-files=all"
  )
abort "uri-idna source must be clean" unless status.success? && changes.empty?
input_pins = {
  "ArabicShaping.txt" =>
    "39afa01e680e27d0fd10b67a9b27be13fbaa3d0efecfb5be45991de9a0d267d0",
  "Blocks.txt" =>
    "c0edefaf1a19771e830a82735472716af6bf3c3975f6c2a23ffbe2580fbbcb15",
  "CaseFolding.txt" =>
    "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183",
  "CompositionExclusions.txt" =>
    "2f239196ef3b5b61db5cc476e9bd80f534d15aa1b74e1be1dea5d042a344c85f",
  "DerivedCoreProperties.txt" =>
    "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08",
  "DerivedJoiningType.txt" =>
    "f39ebe974825d6736aee15582250307aa532b2cfab3caf3f86bd23fddc9c5c4d",
  "HangulSyllableType.txt" =>
    "5a57450afde0d082bc5026f7458649eac3b615490cc7e3d916b0367f1593c0e3",
  "IdnaMappingTable.txt" =>
    "87f05505dc026fdb2bff16132bdc68a8014675836882a9a2b1844540ad3be382",
  "PropList.txt" =>
    "130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd",
  "Scripts.txt" =>
    "9f5e50d3abaee7d6ce09480f325c706f485ae3240912527e651954d2d6b035bf",
  "UnicodeData.txt" =>
    "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c",
  "LICENSE.txt" =>
    "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96"
}.freeze
input_pins.each do |name, sha|
  unless Digest::SHA256.file(File.join(data_dir, name)).hexdigest == sha
    abort "Unicode input mismatch: #{name}"
  end
end

FileUtils.mkdir_p(output)
FileUtils.cp_r(File.join(upstream, "lib", "."), output)
Dir
  .glob(File.join(output, "**/*.rb"))
  .each { |path| File.binwrite(path, File.binread(path).gsub("\r\n", "\n")) }
nfc_dir = File.join(output, "private_nfc17")
unless system(
         RbConfig.ruby,
         File.join(__dir__, "generate-private-nfc.rb"),
         ruby_old,
         data_dir,
         nfc_dir,
         ruby_current
       )
  abort "NFC generation failed"
end
require File.join(nfc_dir, "normalize")

# Generate from pinned data, not the build host's Unicode/NFKC tables. This
# process-local generator override never enters the runtime bundle or Core.
%w[
  code_point
  unicode_data
  base_generator
  idna_generator
  scripts_generator
  uts46_generator
].each { |name| require File.join(upstream, "tasks", name) }
CodePoint.prepend(
  Module.new do
    def nfkc_cf
      return char unless char.valid_encoding?
      DiscussionBridgeIdnaNfc17.normalize(
        casefold(DiscussionBridgeIdnaNfc17.normalize(char, :nfkc)),
        :nfkc
      )
    end
  end
)
unicode = UnicodeData.new("17.0.0", File.dirname(data_dir))
target_data = File.join(output, "uri/idna/data")
%w[unicode_version].each do |name|
  File.binwrite(
    File.join(target_data, "#{name}.rb"),
    BaseGenerator.new(unicode, "#{name}.erb").render
  )
end
File.binwrite(
  File.join(target_data, "scripts.rb"),
  ScriptsGenerator.new(unicode, "scripts.erb").render
)
File.binwrite(
  File.join(target_data, "uts46.rb"),
  UTS46Generator.new(unicode, "uts46.erb").render
)
idna_generator = IDNAGenerator.new(unicode)
%w[
  bidi_classes
  codepoint_classes
  leading_combiners
  virama_combining_classes
].each do |name|
  File.binwrite(
    File.join(target_data, "#{name}.rb"),
    idna_generator.render("#{name}.erb")
  )
end
unless system(
         RbConfig.ruby,
         File.join(__dir__, "generate-joining-types.rb"),
         File.join(data_dir, "DerivedJoiningType.txt"),
         File.join(target_data, "joining_types.rb")
       )
  abort "Joining-type generation failed"
end

replace =
  lambda do |path, before, after|
    source = File.read(path, encoding: "UTF-8")
    unless source.scan(Regexp.new(Regexp.escape(before))).length == 1
      abort "Unexpected pinned source shape: #{path}"
    end
    File.binwrite(path, source.sub(before, after))
  end
mapping = File.join(output, "uri/idna/uts46/mapping.rb")
replace.call(
  mapping,
  "Regexp.new(REGEX_STD3_M_STRING, Regexp::EXTENDED)",
  'Regexp.new(REGEX_STD3_M_STRING == "[]" ? "(?!)" : REGEX_STD3_M_STRING, Regexp::EXTENDED)'
)
replace.call(
  mapping,
  '"[^#{REGEX_V_STRING}#{REGEX_STD3_M_STRING}#{REGEX_STD3_V_STRING}]"',
  '"[^#{[REGEX_V_STRING, REGEX_STD3_M_STRING, REGEX_STD3_V_STRING].reject { |set| set == "[]" }.join}]"'
)
replace.call(
  mapping,
  '"[^#{REGEX_V_STRING}#{REGEX_D_STRING}#{REGEX_STD3_M_STRING}#{REGEX_STD3_V_STRING}]"',
  '"[^#{[REGEX_V_STRING, REGEX_D_STRING, REGEX_STD3_M_STRING, REGEX_STD3_V_STRING].reject { |set| set == "[]" }.join}]"'
)
replace.call(
  mapping,
  'require_relative "../data/uts46"',
  "require_relative \"../data/uts46\"\nrequire_relative \"../../../private_nfc17/normalize\""
)
replace.call(
  mapping,
  "output.unicode_normalize!(:nfc)",
  "DiscussionBridgeIdnaNfc17.normalize(output, :nfc)"
)
label = File.join(output, "uri/idna/validation/label.rb")
replace.call(
  label,
  "# frozen_string_literal: true",
  "# frozen_string_literal: true\n\nrequire_relative \"../../../private_nfc17/normalize\""
)
replace.call(
  label,
  "label.unicode_normalized?(:nfc)",
  "DiscussionBridgeIdnaNfc17.normalized?(label, :nfc)"
)
context = File.join(output, "uri/idna/validation/contextj.rb")
replace.call(
  context,
  'CONTEXTJ_REGEX = Regexp.new("[#{CODEPOINT_CLASSES[\'CONTEXTJ\']}]").freeze',
  "CONTEXTJ_REGEX = Regexp.new(\"[\#{CODEPOINT_CLASSES['CONTEXTJ']}]\").freeze\n          VIRAMA_REGEX = Regexp.new(VIRAMA_COMBINING_CLASSES).freeze"
)
context_source = File.read(context, encoding: "UTF-8")
unless context_source.scan(
         "VIRAMA_COMBINING_CLASSES.match?(label[pos - 1])"
       ).length == 2
  abort "Unexpected ContextJ source"
end
context_source.gsub!(
  "VIRAMA_COMBINING_CLASSES.match?(label[pos - 1])",
  "VIRAMA_REGEX.match?(label[pos - 1])"
)
context_source.sub!(
  "                  break\n                end\n",
  "                  break\n                end\n                break unless joining_type == 0x54\n"
)
context_source.sub!(
  "return true if [0x52, 0x44].include?(joining_type)",
  "return true if [0x52, 0x44].include?(joining_type)\n                break unless joining_type == 0x54"
)
File.binwrite(context, context_source)
entry = File.join(output, "uri/idna.rb")
replace.call(
  entry,
  'require_relative "idna/version"',
  "require_relative \"idna/version\"\nrequire_relative \"idna/data/unicode_version\""
)
Dir
  .glob(File.join(output, "**/*.rb"))
  .each do |path|
    # Generated ERB output can retain CRLF on Linux. Normalize it before the
    # exact private-namespace transformation, not just before source copying.
    source = File.read(path, encoding: "UTF-8").gsub("\r\n", "\n")
    source.gsub!(
      "module URI\n  module IDNA",
      "module DiscussionBridge\n  module CmsIdnaVendor"
    )
    source.gsub!("DiscussionBridgeIdnaNfc17", "DiscussionBridge::CmsIdnaNfc17")
    abort "Global URI namespace survived" if source.match?(/^\s*module URI\b/)
    if path == File.join(nfc_dir, "tables.rb")
      source.sub!(
        "module DiscussionBridge::CmsIdnaNfc17  # :nodoc:",
        "module DiscussionBridge::CmsIdnaNfc17  # :nodoc:\n  UNICODE_VERSION = \"17.0.0\".freeze"
      )
    end
    File.binwrite(path, source)
  end
{
  "LICENSE_URI_IDNA.txt" => File.join(upstream, "LICENSE.txt"),
  "LICENSE_RUBY_BSD.txt" => File.join(ruby_old, "BSDL"),
  "LICENSE_UNICODE.txt" => File.join(data_dir, "LICENSE.txt")
}.each do |name, source|
  File.binwrite(
    File.join(output, name),
    File.binread(source).gsub("\r\n", "\n")
  )
end

members =
  Dir
    .glob(File.join(output, "**/*"))
    .select { |path| File.file?(path) }
    .sort
    .map do |path|
      {
        "path" => path.delete_prefix(output + "/"),
        "bytes" => File.size(path),
        "sha256" => Digest::SHA256.file(path).hexdigest
      }
    end
manifest = {
  "format" => 1,
  "scope" =>
    "Private UTS46 ToASCII URL-authority validation only; no global URI, String or native normalizer replacement.",
  "unicode_version" => "17.0.0",
  "uri_idna_version" => "0.3.1",
  "uri_idna_commit" => expected_commit,
  "ruby_compatible_engine_commit" => "0581089df9f0af0fe6b64cb8167987c211100947",
  "ruby_composition_and_generator_commit" =>
    "a6c4c8e8e6ab9a280f5dd4f757785669fddb897e",
  "owned_changes" => [
    "Private namespace and LF transport",
    "Pinned Unicode17 data and complete derived joining types",
    "Empty STD3-set compatibility",
    "Correct virama regexp direction and transparent-only ContextJ scans",
    "Private pinned NFC with maintained Unicode16+ composition correction and Ruby3.3-compatible cache/syntax",
    "No build-host NFKC dependency in generated codepoint properties"
  ],
  "unicode_input_sha256" => input_pins,
  "members" => members
}
File.binwrite(
  File.join(output, "MANIFEST.json"),
  JSON.pretty_generate(manifest) + "\n"
)
puts JSON.generate(
       members: members.length,
       manifest_sha256:
         Digest::SHA256.file(File.join(output, "MANIFEST.json")).hexdigest
     )
