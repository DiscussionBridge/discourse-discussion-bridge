# frozen_string_literal: true

# Author-local source/route assembly checks. No Rails or database execution.
require "json"
require "digest"

root = File.expand_path("../..", __dir__)
plugin = File.read(File.join(root, "plugin.rb"))
contract_path = File.join(root, "lib/discussion_bridge/cms_contract.json")
schema_path = File.join(root, "lib/discussion_bridge/cms_protocol_types.json")
raise "contract pin" unless Digest::SHA256.file(contract_path).hexdigest == "df31c5d2fc387a8b12b388438450eccd97966de34c82b1bf417634b21a36b495"
raise "schema pin" unless Digest::SHA256.file(schema_path).hexdigest == "8563a9b1346e3bf82635bd65a46bb1e25415a1003d7432f8fcb8c1c6e4f03c14"
contract = JSON.parse(File.read(contract_path))
descriptor = JSON.parse(File.read(File.join(root, "discussionbridge-release.json")))
raise "descriptor candidate" unless descriptor.fetch("candidate_id") == contract.fetch("candidate_id")
raise "descriptor wire" unless descriptor.fetch("wire_version") == contract.fetch("wire_version")
raise "descriptor package" unless descriptor.fetch("component").fetch("version") == contract.fetch("implementation_version") &&
  descriptor.fetch("family").fetch("version") == contract.fetch("implementation_version")
raise "descriptor release/status" unless descriptor.fetch("release_version").nil? &&
  descriptor.fetch("status") == "implementation_candidate_not_exact_approved_not_frozen"
raise "descriptor normative" unless descriptor.fetch("normative_sha256") == Digest::SHA256.file(contract_path).hexdigest
raise "descriptor schema" unless descriptor.fetch("schema_sha256") == Digest::SHA256.file(schema_path).hexdigest
expected = contract.fetch("routes").map do |route|
  [route.fetch("method"), route.fetch("path").delete_prefix("/discussion-bridge").delete_suffix(".json").gsub(/\{([^}]+)\}/, ':\1')]
end.sort
actual = plugin.scan(/^    (get|post|put) "(\/v4\/[^\"]+)" => "([^\"]+)"/).map do |method, path, handler|
  controller, action = handler.split("#", 2)
  source = File.read(File.join(root, "app/controllers/discussion_bridge/#{controller}_controller.rb"))
  inherited_work_action = controller == "cms_work" && %w[renew acknowledge fail prepare finalize abort].include?(action)
  raise "missing action #{handler}" unless inherited_work_action || source.match?(/\bdef #{Regexp.escape(action)}\b/)
  [method.upcase, path]
end.sort
raise "V4 route mismatch" unless actual == expected && actual.length == 36
raise "old wire route" if plugin.match?(%r{["']/v[12]/})
requires = plugin.scan(/require_relative "([^"]+)"/).flatten
requires.each { |path| raise "missing loader member #{path}" unless File.file?(File.join(root, "#{path}.rb")) }
native = plugin.scan(/^    (get|post|put) "(\/admin\/[^\"]+)" => "discussion_bridge\/([^\"]+)"/)
expected_native = contract.fetch("native_interfaces").flat_map do |route|
  route.fetch("method").split("/").map do |method|
    [method, route.fetch("path").gsub(/\{connection_id\}/, ":id").gsub(/\{([^}]+)\}/, ':\1')]
  end
end.sort
raise "native route mismatch" unless native.map { |method, path, _| [method.upcase, path] }.sort == expected_native
files = Dir.glob(File.join(root, "**/*.rb"))
files.each { |path| RubyVM::InstructionSequence.compile_file(path) }
puts JSON.generate(v4_routes: actual.length, native_actions: native.length, loader_members: requires.length,
  ruby_syntax_files: files.length, pins: "matched", limits: "source assembly and Ruby syntax only; Rails/PostgreSQL/native rendering unexecuted")
