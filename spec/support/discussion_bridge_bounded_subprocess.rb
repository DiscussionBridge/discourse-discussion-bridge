# frozen_string_literal: true

require "open3"

module DiscussionBridge
  module SpecSupport
    module BoundedSubprocess
      class TimeoutError < StandardError
        attr_reader :stdout, :stderr

        def initialize(timeout_seconds:, stdout:, stderr:)
          @stdout = stdout
          @stderr = stderr
          super(
            "subprocess exceeded #{timeout_seconds} seconds\n" \
              "stdout:\n#{stdout}\n" \
              "stderr:\n#{stderr}",
          )
        end
      end

      private

      def run_bounded_subprocess(environment, *command, chdir:, timeout_seconds: 180,
                                 termination_grace_seconds: 2)
        stdout_text = +""
        stderr_text = +""
        wait_thread = nil
        readers = []

        Open3.popen3(environment, *command, chdir: chdir, pgroup: true) do |stdin, stdout, stderr, child|
          wait_thread = child
          stdin.close
          readers = [
            Thread.new { stdout_text << stdout.read },
            Thread.new { stderr_text << stderr.read },
          ]

          unless child.join(timeout_seconds)
            terminate_process_group(child, grace_seconds: termination_grace_seconds)
            readers.each(&:join)
            raise TimeoutError.new(
              timeout_seconds: timeout_seconds,
              stdout: stdout_text,
              stderr: stderr_text,
            )
          end

          readers.each(&:join)
          return [stdout_text, stderr_text, child.value]
        end
      ensure
        terminate_process_group(wait_thread, grace_seconds: termination_grace_seconds) if
          wait_thread&.alive?
        readers.each { |reader| reader.join(termination_grace_seconds) }
      end

      def terminate_process_group(wait_thread, grace_seconds:)
        return unless wait_thread&.alive?

        signal_process_group("TERM", wait_thread.pid)
        return if wait_thread.join(grace_seconds)

        signal_process_group("KILL", wait_thread.pid)
        wait_thread.join
      end

      def signal_process_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
