# frozen_string_literal: true

require_relative "sys"

module Robur
  # One agent turn under a watchdog (port of ratchet/lib/run-turn.sh's watch
  # loop; classification lives in Classifier, T4.4). Output streams to the turn
  # file so size growth doubles as the liveness signal for the stall kill.
  class Turn
    Result = Struct.new(:status, :kill_reason, :elapsed, keyword_init: true)

    # Runs cmd with output redirected to turn_file. kill_reason is nil,
    # "deadline-<TURN_TIMEOUT>s" or "stall-<STALL_TIMEOUT>s".
    def self.run(cmd:, turn_file:, turn_timeout:, stall_timeout:, poll_interval:,
                 proc: Sys::Proc.new, clock: Sys::Clock.new)
      File.open(turn_file, "w") do |f|
        pid = proc.spawn(cmd, out: f, err: f)
        start = clock.monotonic
        last_size = 0
        last_growth = start
        reason = nil
        detected = nil

        loop do
          now = clock.monotonic
          if now - start >= turn_timeout
            reason = "deadline-#{turn_timeout}s"
            detected = now
            break
          end
          sz = File.exist?(turn_file) ? File.size(turn_file) : 0
          if sz > last_size
            last_size = sz
            last_growth = clock.monotonic
          elsif sz.positive? && now - last_growth >= stall_timeout
            reason = "stall-#{stall_timeout}s"
            detected = now
            break
          end
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return Result.new(status: status, kill_reason: nil, elapsed: clock.monotonic - start) if status

          clock.sleep(poll_interval)
        end

        proc.kill(pid)
        status = proc.reap(pid)
        Result.new(status: status, kill_reason: reason, elapsed: detected - start)
      end
    end
  end

  module Sys
    class Proc
      def spawn(cmd, out:, err:)
        Process.spawn(*cmd, out: out, err: err)
      end

      def reap(pid)
        Process.wait(pid)
        $?
      end

      # TERM, grace period, then KILL — mirror of bash's kill/pkill/kill -9.
      def kill(pid)
        Process.kill("TERM", pid)
        sleep(2)
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
