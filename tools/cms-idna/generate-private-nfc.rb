# frozen_string_literal: true

# Isolated build process: unmodified maintained Ruby table generator + pinned
# official Unicode inputs. Runtime changes are mechanical private namespacing.
require "digest"
require "erb"
require "fileutils"
source_dir, data_dir, output_dir, current_dir =
  ARGV.map { |path| File.expand_path(path) }
pins = {
  "template_unicode_norm_gen.tmpl" =>
    "3b5fb00f97e19e3a225e0f1ea0369a2ac0597ad5a10d31de573bf51b2518277e",
  "lib_unicode_normalize_normalize.rb" =>
    "fde37bf91f9e7fb3c24a18bced1829d1ab9c16a6e44c7b426dfe4772edb5ff58"
}
pins.each do |name, expected|
  unless Digest::SHA256.file(File.join(source_dir, name)).hexdigest == expected
    abort "Ruby source mismatch: #{name}"
  end
end
unless Digest::SHA256.file(File.join(data_dir, "UnicodeData.txt")).hexdigest ==
         "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"
  abort "Unicode data mismatch"
end
abort "Wrong data version" unless data_dir.end_with?("/17.0.0")
unless Digest::SHA256.file(
         File.join(data_dir, "CompositionExclusions.txt")
       ).hexdigest ==
         "2f239196ef3b5b61db5cc476e9bd80f534d15aa1b74e1be1dea5d042a344c85f"
  abort "Composition exclusion mismatch"
end
current_pins = {
  "template_unicode_norm_gen.tmpl" =>
    "6f23803216c134b28a43e0b127fdc53646a3298fc1b524be4fd84391d8eefdf2",
  "lib_unicode_normalize_normalize.rb" =>
    "df5a83897f8b62a186c1c5e2729846267b5f2fdf2a9f51b5caf295dd1cf21391"
}
current_pins.each do |name, expected|
  unless Digest::SHA256.file(File.join(current_dir, name)).hexdigest == expected
    abort "Current Ruby source mismatch: #{name}"
  end
end
template =
  File.read(
    File.join(current_dir, "template_unicode_norm_gen.tmpl"),
    encoding: "UTF-8"
  )
normalizer =
  File.read(
    File.join(source_dir, "lib_unicode_normalize_normalize.rb"),
    encoding: "UTF-8"
  )
# Take the maintained Unicode16+ composition fix verbatim, retaining the older
# compatible cache/block syntax instead of introducing current Ruby requirements.
current_normalizer =
  File.read(
    File.join(current_dir, "lib_unicode_normalize_normalize.rb"),
    encoding: "UTF-8"
  )
method_pattern =
  /^  def self\.nfc_one\(string\)\n.*?(?=^  def self\.normalize)/m
unless normalizer.scan(method_pattern).length == 1 &&
         current_normalizer.scan(method_pattern).length == 1
  abort "Unexpected maintained method shape"
end
normalizer.sub!(method_pattern, current_normalizer.match(method_pattern)[0])
ARGV.replace([data_dir])
vpath = File
tables = ERB.new(template, trim_mode: "%-").result(binding)
# A private generated bundle is pinned to its own input hashes, not to the host
# Ruby's unrelated built-in Unicode version. Do not alter Encoding or String.
host_guard =
  /Encoding::UNICODE_VERSION == "17\.0\.0" or\n  raise "Unicode version mismatch: 17\.0\.0 expected but #\{Encoding::UNICODE_VERSION\}"\n/
abort "Unexpected host guard" unless tables.scan(host_guard).length == 1
tables.sub!(
  host_guard,
  "# Private Unicode 17.0.0 data; source/input SHA-256 pins checked by generator.\n"
)
namespace = "module UnicodeNormalize  # :nodoc:"
replacement = "module DiscussionBridgeIdnaNfc17  # :nodoc:"
[tables, normalizer].each do |source|
  abort "Unexpected namespace shape" unless source.scan(namespace).length == 1
  source.sub!(namespace, replacement)
end
FileUtils.mkdir_p(output_dir)
File.binwrite(File.join(output_dir, "tables.rb"), tables)
File.binwrite(File.join(output_dir, "normalize.rb"), normalizer)
puts "Generated private Unicode17 normalization: Ruby3.3-compatible engine + maintained Unicode16+ composition/generator correction at a6c4c8e8e6ab9a280f5dd4f757785669fddb897e"
