# frozen_string_literal: true

# Mechanical qualification data generation from Unicode's complete derived
# property file, including transparent marks absent from ArabicShaping.txt.
require "digest"
input, output = ARGV
bytes = File.binread(input)
expected_version = bytes.include?("DerivedJoiningType-17.0.0.txt")
abort "Unexpected Unicode version" unless expected_version
entries = {}
bytes.each_line do |line|
  match = /\A([0-9A-F]+)(?:\.\.([0-9A-F]+))?\s*;\s*([CDLRTU])\b/.match(line)
  next unless match
  first = match[1].to_i(16)
  last = match[2] ? match[2].to_i(16) : first
  abort "Invalid property range" if first > last || last > 0x10ffff
  (first..last).each do |point|
    abort "Duplicate property" if entries.key?(point)
    entries[point] = match[3].ord
  end
end
abort "Incomplete property source" if entries.length <= 2000
lines =
  entries.sort.map do |point, type|
    "      #{[point].pack("U").dump} => #{type},"
  end
File.binwrite(output, <<~RUBY)
  # frozen_string_literal: true

  # Generated from Unicode 17.0.0 extracted/DerivedJoiningType.txt.
  # Input SHA-256: #{Digest::SHA256.hexdigest(bytes)}
  module URI
    module IDNA
      JOINING_TYPES = {
  #{lines.join("\n")}
      }.freeze
    end
  end
RUBY
puts "Generated #{entries.length} joining-type entries"
