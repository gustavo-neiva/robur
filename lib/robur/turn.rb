# frozen_string_literal: true

require_relative "sys"

module Robur
  # One agent turn under a watchdog (port of ratchet/lib/run-turn.sh's watch
  # loop; classification lives in Classifier, T4.4). Output streams to the turn
  # file so size growth doubles as the liveness signal for the stall kill.
  class Turn
    Result = Struct.new(:status, :kill_reason, :elapsed, keyword_init: true)

    # Runs cmd with output redirected to turn_file. kill_reason is nil,
    # "deadline-<TURN_TIMEOUT>s", "stall-<STALL_TIMEOUT>s", or
    # "token-seen" (audit velocity fix: bash run-turn.sh:81 breaks the
    # watchdog the moment a completion token appears — pi can idle 10-30s
    # after printing it, which is hours of wall-clock across a run).
    # early_tokens: array of tokens (step/done) that end the turn early.
    def self.run(cmd:, turn_file:, turn_timeout:, stall_timeout:, poll_interval:,
                 chdir: nil, proc: Sys::Proc.new, clock: Sys::Clock.new, early_tokens: nil)
      File.open(turn_file, "w") do |f|
        # bash cd's into REPO_DIR in main() before every turn: the agent must
        # run in the repo or stubs/agents edit the wrong tree (infinite step loop).
        pid = proc.spawn(cmd, out: f, err: f, chdir: chdir)
        start = clock.monotonic
        last_size = 0
        last_growth = start
        reason = nil
        detected = nil

        loop do
          # Liveness check first (mirrors bash's `while kill -0 $pid`): a
          # process that already exited must never be reclassified as a
          # deadline/stall kill just because the check lands on the same
          # tick the cap is reached.
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return Result.new(status: status, kill_reason: nil, elapsed: clock.monotonic - start) if status

          now = clock.monotonic
          sz = File.exist?(turn_file) ? File.size(turn_file) : 0
          # token-seen: new bytes contain a completion token -> the turn is
          # DONE. Grace-reap first: a well-behaved agent exits within moments
          # of the token, and a reaped exit status beats a TERM kill's 143
          # (kills the harness flake where poll timing decides the exit code).
          # Still hanging after the grace -> kill instead of waiting out the
          # agent's shutdown tail.
          if early_tokens && sz > last_size && token_in?(turn_file, early_tokens)
            clock.sleep(0.2)
            _, wstatus = Process.waitpid2(pid, Process::WNOHANG)
            return Result.new(status: wstatus, kill_reason: nil, elapsed: clock.monotonic - start) if wstatus

            reason = "token-seen"
            detected = now
            break
          end
          if now - start >= turn_timeout
            reason = "deadline-#{turn_timeout}s"
            detected = now
            break
          end
          if sz > last_size
            last_size = sz
            last_growth = clock.monotonic
          elsif sz.positive? && now - last_growth >= stall_timeout
            reason = "stall-#{stall_timeout}s"
            detected = now
            break
          end

          clock.sleep(poll_interval)
        end

        proc.kill(pid)
        status = proc.reap(pid)
        Result.new(status: status, kill_reason: reason, elapsed: detected - start)
      end
    end

    # Scan the turn file (binary-safe) for any early-exit token.
    def self.token_in?(turn_file, tokens)
      content = File.open(turn_file, "rb") { |f| f.read }
      tokens.any? { |t| content.include?(t) }
    rescue StandardError
      false
    end
  end

  module Sys
    class Proc
      def spawn(cmd, out:, err:, chdir: nil)
        opts = { out: out, err: err }
        opts[:chdir] = chdir if chdir
        Process.spawn(*cmd, **opts)
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
