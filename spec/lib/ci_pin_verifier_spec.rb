# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "open3"
require "tmpdir"

# This spec exercises a standalone script, not a class or module.
RSpec.describe "DiscussionBridge CI pin verifier" do # rubocop:disable RSpec/DescribeClass
  let(:root) { File.expand_path("../..", __dir__) }

  it "rejects sequence-first mutable actions and compatibility Core overrides" do
    Dir.mktmpdir("discussion-bridge-ci-pins") do |temporary|
      FileUtils.mkdir_p(File.join(temporary, "script"))
      FileUtils.mkdir_p(File.join(temporary, ".github", "workflows"))
      FileUtils.cp(File.join(root, "script", "verify_ci_pins.rb"), File.join(temporary, "script"))
      %w[Gemfile.lock pnpm-lock.yaml].each do |lockfile|
        FileUtils.cp(File.join(root, lockfile), File.join(temporary, lockfile))
      end
      %w[discourse-plugin.yml discourse-plugin-pinned.yml].each do |workflow|
        FileUtils.cp(
          File.join(root, ".github", "workflows", workflow),
          File.join(temporary, ".github", "workflows", workflow),
        )
      end

      script = File.join(temporary, "script", "verify_ci_pins.rb")
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)
      expect(status).to be_success, stderr

      pinned = File.join(temporary, ".github", "workflows", "discourse-plugin-pinned.yml")
      baseline = File.read(pinned)
      File.write(pinned, baseline.sub(/(- uses: actions\/checkout)@[0-9a-f]{40}/, '\\1@main'))
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)
      expect(status).not_to be_success
      expect(stderr).to include("action is not pinned")

      File.write(pinned, baseline.sub("core_ref = ENV.fetch(\"CORE_REF\")", 'core_ref = "release/2026.09"'))
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)
      expect(status).not_to be_success
      expect(stderr).to include("Compatibility workflow may override")

      File.write(
        pinned,
        baseline.sub(
          "04883e331b31448d6255fa058f0e1c7e8657c004da1f8a1c04eb28855a37ec6c",
          "0" * 64,
        ),
      )
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)
      expect(status).not_to be_success
      expect(stderr).to include("Playwright Chromium artifact is not exact and checksum-pinned")

      File.write(pinned, baseline.sub("env -u CI bundle exec rspec", "bundle exec rspec"))
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)
      expect(status).not_to be_success
      expect(stderr).to include("Fresh-process assurance must run outside")
    end
  end
end
