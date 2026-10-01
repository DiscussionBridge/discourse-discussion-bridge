# frozen_string_literal: true

require "rails_helper"
require "open3"
require "rbconfig"
require "timeout"

RSpec.describe "R3-F02 publication-policy isolation across fresh processes" do
  self.use_transactional_tests = false

  it "retains dynamic cleanup and static work identity across three Rails boots" do
    restart_schema = "db_r3_f02_restart_#{SecureRandom.hex(6)}"
    pids = []
    begin
      {
        "prepare" => /R3-F02 prepare complete pid=(\d+)/,
        "resume" => /R3-F02 resume complete pid=(\d+)/,
        "verify" => /R3-F02 verify complete pid=(\d+)/,
      }.each do |phase, expected_output|
        stdout, stderr, status = run_restart_phase(restart_schema, phase)
        expect(status).to be_success, "#{phase} failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
        match = stdout.match(expected_output)
        expect(match).to be_present, "#{phase} omitted its completion receipt\n#{stdout}\n#{stderr}"
        pids << Integer(match[1], 10)
      end
      expect(pids.uniq.length).to eq(3)
    ensure
      stdout, stderr, status = run_restart_phase(restart_schema, "cleanup")
      expect(status).to be_success, "cleanup failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
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
    Timeout.timeout(240) do
      Open3.capture3(
        environment,
        RbConfig.ruby,
        Rails.root.join("bin/rails").to_s,
        "runner",
        runner,
        chdir: Rails.root.to_s,
      )
    end
  end
end
