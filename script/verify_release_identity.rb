# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
manifest_path = File.join(root, "discussionbridge-release.json")
plugin_path = File.join(root, "plugin.rb")
boundary_path = File.join(root, "lib", "discussion_bridge", "adapter_request_boundary.rb")

manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
plugin = File.read(plugin_path, encoding: "UTF-8")
boundary = File.read(boundary_path, encoding: "UTF-8")

unique_capture = lambda do |text, pattern, name|
  matches = text.scan(pattern).flatten
  abort "#{name} must occur exactly once" unless matches.length == 1

  matches.fetch(0)
end

header_version = unique_capture.call(plugin, /^# version:\s*(\S+)\s*$/, "plugin header version")
runtime_version = unique_capture.call(plugin, /^\s*VERSION = "([^"]+)"\s*$/, "runtime plugin version")
runtime_contract = unique_capture.call(plugin, /^\s*CONTRACT_VERSION = "([^"]+)"\s*$/, "runtime contract version")
boundary_contract = unique_capture.call(
  boundary,
  /^\s*CONTRACT_VERSION = "([^"]+)"\s*$/,
  "request-boundary contract version",
)

component_version = manifest.fetch("component").fetch("version")
family_version = manifest.fetch("family").fetch("version")
manifest_contract = manifest.fetch("adapterProtocol")
expected_family_version = component_version.sub(/\.alpha\.(\d+)\z/, "-alpha.\\1")

abort "component manifest does not match plugin header" unless component_version == header_version
abort "runtime plugin version does not match plugin header" unless runtime_version == header_version
abort "family manifest does not match component identity" unless family_version == expected_family_version
abort "runtime contract version does not match release manifest" unless runtime_contract == manifest_contract
abort "request-boundary contract version does not match release manifest" unless boundary_contract == manifest_contract

puts "Release identities agree: plugin #{runtime_version}; Adapter Protocol #{runtime_contract}"
