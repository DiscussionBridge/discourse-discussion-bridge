# frozen_string_literal: true

require "rails_helper"
require "rbconfig"
require_relative "../support/discussion_bridge_bounded_subprocess"

RSpec.describe "R3-F02 publication-policy isolation across fresh processes", :fresh_process,
               order: :defined do
  include DiscussionBridge::SpecSupport::BoundedSubprocess

  self.use_transactional_tests = false

  # The ordered examples intentionally share only the external schema name and
  # process receipts; each phase itself runs in a separate Rails process.
  # rubocop:disable RSpec/BeforeAfterAll
  before(:context) do
    @restart_schema = "db_r3_f02_restart_#{SecureRandom.hex(6)}"
    @phase_pids = []
  end

  after(:context) do
    stdout, stderr, status = run_restart_phase(@restart_schema, "cleanup")
    raise "cleanup failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}" unless status.success?
  end
  # rubocop:enable RSpec/BeforeAfterAll

  {
    "prepare" => /R3-F02 prepare complete pid=(\d+)/,
    "resume" => /R3-F02 resume complete pid=(\d+)/,
    "verify" => /R3-F02 verify complete pid=(\d+)/,
  }.each do |phase, expected_output|
    it "completes the #{phase} fresh-process phase" do
      stdout, stderr, status = run_restart_phase(@restart_schema, phase)
      expect(status).to be_success, "#{phase} failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
      match = stdout.match(expected_output)
      expect(match).to be_present, "#{phase} omitted its completion receipt\n#{stdout}\n#{stderr}"
      @phase_pids << Integer(match[1], 10)
      expect(@phase_pids.uniq.length).to eq(3) if phase == "verify"
    end
  end

  def run_restart_phase(restart_schema, phase)
    runner = File.expand_path(
      "../fixtures/publication_policy_isolation_restart/runner.rb",
      __dir__,
    )
    environment = {
      "DISABLE_BOOTSNAP" => "1",
      "DISCUSSION_BRIDGE_R3_F02_PHASE" => phase,
      "DISCUSSION_BRIDGE_R3_F02_SCHEMA" => restart_schema,
      "LOAD_PLUGINS" => "1",
      "RAILS_ENV" => "test",
    }
    run_bounded_subprocess(
      environment,
      RbConfig.ruby,
      Rails.root.join("bin/rails").to_s,
      "runner",
      runner,
      chdir: Rails.root.to_s,
    )
  end
end
