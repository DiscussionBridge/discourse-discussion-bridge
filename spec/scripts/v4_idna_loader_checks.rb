# frozen_string_literal: true

# Local package/load-integrity checks, not native Rails or URL authority proof.
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

root = File.expand_path("../..", __dir__)
source = File.join(root, "lib/discussion_bridge")
checks = 0
cases = %w[
  intact
  modified_entry
  missing_entry
  modified_manifest
  missing_manifest
  forged_manifest
  extra_member
  hidden_member
]

Dir.mktmpdir("discussionbridge-idna-loader-") do |temporary|
  cases.each do |kind|
    fixture = File.join(temporary, kind)
    bundle = File.join(fixture, "vendor/cms_idna")
    FileUtils.mkdir_p(File.dirname(bundle))
    FileUtils.cp_r(File.join(source, "vendor/cms_idna"), bundle)
    helper = File.join(fixture, "cms_url_authority.rb")
    FileUtils.cp(File.join(source, "cms_url_authority.rb"), helper)
    manifest_path = File.join(bundle, "MANIFEST.json")
    entry = File.join(bundle, "uri/idna.rb")
    marker = File.join(fixture, "dependency-executed")

    if %w[modified_entry forged_manifest].include?(kind)
      prefix =
        "File.write(ENV.fetch('DISCUSSIONBRIDGE_TEST_MARKER'), 'executed')\n"
      File.binwrite(entry, prefix + File.binread(entry))
    end
    case kind
    when "missing_entry"
      File.unlink(entry)
    when "modified_manifest"
      File.binwrite(manifest_path, File.binread(manifest_path) + "\n")
    when "missing_manifest"
      File.unlink(manifest_path)
    when "forged_manifest"
      manifest = JSON.parse(File.binread(manifest_path))
      member =
        manifest
          .fetch("members")
          .find { |item| item.fetch("path") == "uri/idna.rb" }
      member["bytes"] = File.size(entry)
      member["sha256"] = Digest::SHA256.file(entry).hexdigest
      File.binwrite(manifest_path, JSON.pretty_generate(manifest) + "\n")
    when "extra_member", "hidden_member"
      name = kind == "hidden_member" ? ".unexpected.rb" : "unexpected.rb"
      File.binwrite(File.join(bundle, name), "# Unexpected package member\n")
    end

    code = 'require ARGV.fetch(0); puts "loaded"'
    stdout, stderr, status =
      Open3.capture3(
        { "DISCUSSIONBRIDGE_TEST_MARKER" => marker },
        RbConfig.ruby,
        "-e",
        code,
        helper
      )
    if File.exist?(marker)
      raise "Dependency executed before verification: #{kind}"
    end
    if kind == "intact"
      unless status.success? && stdout.strip == "loaded" && stderr.empty?
        raise "Intact bundle failed: #{stderr}"
      end
    elsif status.success? || !stdout.empty? ||
          !stderr.include?("V4 private IDNA")
      raise "Bundle did not fail closed: #{kind}"
    end
    checks += 1
  end
end

puts JSON.generate(
       checks: checks,
       cases: cases,
       dependency_executed_before_verification: false,
       temporary_fixture_cleanup: "completed",
       limitations:
         "Package/load integrity only; no Rails, database, origin or installed qualification"
     )
