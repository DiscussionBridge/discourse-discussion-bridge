# frozen_string_literal: true

require "rails_helper"
require "rbconfig"
require_relative "../support/discussion_bridge_bounded_subprocess"

RSpec.describe DiscussionBridge::SpecSupport::BoundedSubprocess do
  include described_class

  it "terminates and reaps a timed-out subprocess group" do
    script = "STDOUT.sync = true; puts Process.pid; sleep 60"

    error = nil
    expect do
      run_bounded_subprocess(
        {},
        RbConfig.ruby,
        "-e",
        script,
        chdir: Rails.root.to_s,
        timeout_seconds: 2,
        termination_grace_seconds: 0.2,
      )
    end.to raise_error(described_class::TimeoutError) { |exception| error = exception }

    expect(error.stdout).to match(/\A\d+\n\z/)
    child_pid = Integer(error.stdout.lines.first, 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    child_alive = true
    while child_alive && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        Process.kill(0, child_pid)
        sleep 0.05
      rescue Errno::ESRCH
        child_alive = false
      end
    end
    expect(child_alive).to eq(false)
  end
end
