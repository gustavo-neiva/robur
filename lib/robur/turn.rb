# frozen_string_literal: true

require_relative "sys"

module Robur
  # One agent turn under a watchdog (classification lives in Classifier).
  # Output streams to the turn file so size growth doubles as the liveness
  # signal for the stall kill.
  class Turn
    Result = Struct.new(:status, :kill_reason, :elapsed, keyword_init: true)

    # Runs cmd with output redirected to turn_file. kill_reason is nil,
    # "deadline-<TURN_TIMEOUT>s", "stall-<STALL_TIMEOUT>s", or
    # "token-seen" (audit velocity fix: the watchdog breaks the moment a
    # completion token appears — pi can idle 10-30s after printing it, which
    # is hours of wall-clock across a run).
    # early_tokens: array of tokens (step/done) that end the turn early.
    def self.run(cmd:, turn_file:, turn_timeout:, stall_timeout:, poll_interval:,
                 chdir: nil, proc: Sys::Proc.new, clock: Sys::Clock.new, early_tokens: nil)
      File.open(turn_file, "w") do |f|
        # The turn runs with the repo as cwd: an agent started elsewhere
        # edits the wrong tree and the loop never makes progress.
        pid = proc.spawn(cmd, out: f, err: f, chdir: chdir)
        start = clock.monotonic
        last_size = 0
        last_growth = start
        reason = nil
        detected = nil
        # Incremental token scan: re-reading the whole turn file on every
        # growth tick is quadratic (production turn files reach ~1.8MB at a
        # 3s poll). Only bytes past last_size are new, so scan from there,
        # rewound by max_token-1 so a token straddling a poll boundary is
        # still seen.
        max_token = early_tokens.to_a.map { |t| t.to_s.bytesize }.max.to_i

        loop do
          # Liveness check first: a process that already exited must never
          # be reclassified as a
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
          if early_tokens && sz > last_size &&
             token_in?(turn_file, early_tokens, from: [last_size - (max_token - 1), 0].max)
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

    # pi in -p mode buffers its ENTIRE output until exit — no liveness signal
    # for the watchdog, nothing live for `watch`, no token-seen early kill.
    # --mode json makes pi stream events to stdout as they happen (mirrors
    # bash run-turn.sh:36-40). Only pi has these modes; other agents untouched.
    def self.pi_json?(agent_cmd) = File.basename(agent_cmd.to_s) == "pi"

    # Context profiles per turn kind (measured prompt-side tokens/turn,
    # 2026-09-04: full 18.5K / context-only 14.9K / bare 10.6K). Step turns
    # run bare: the quoted task block is the spec, the gate enforces repo
    # conventions, AGENTS.md is read on demand. Plan turns keep the full
    # stack — PLAN.seed.md points the author at the plan-authoring skill.
    # Review keeps AGENTS.md context (the repo's design decisions are the
    # review criteria) but drops skills (personas are inlined in the
    # REVIEW.prompt.md template).
    CONTEXT_PROFILES = {
      step:   ["--mode", "json", "--no-skills", "--no-context-files"],
      plan:   ["--mode", "json"],
      review: ["--mode", "json", "--no-skills"]
    }.freeze

    def self.mode_args(agent_cmd, kind: :step)
      return [] unless pi_json?(agent_cmd)

      CONTEXT_PROFILES.fetch(kind, CONTEXT_PROFILES[:step])
    end

    # Scan the turn file (binary-safe) for any early-exit token, reading only
    # from byte offset `from` onward. The caller rewinds `from` by
    # max_token-1 bytes so a token split across two polls is not missed;
    # `from: 0` reproduces the original whole-file scan.
    #
    # json mode: a token counts only inside a completed assistant text event
    # (the Classifier's rule). The streamed user-message echo and thinking
    # deltas quote the token names in prose; a raw substring match on those
    # TERM-killed every turn at the first poll and the loop classified it
    # :empty across all models (2026-09-04 outage). Windows without JSON
    # events keep the raw substring behavior for text-mode agents.
    def self.token_in?(turn_file, tokens, from: 0)
      content = File.open(turn_file, "rb") do |f|
        f.seek(from) if from.positive?
        f.read
      end
      return false if content.nil?

      if content.include?("\"type\"")
        content.each_line.any? { |l| l.include?("\"text_end\"") && tokens.any? { |t| l.include?(t) } }
      else
        tokens.any? { |t| content.include?(t) }
      end
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

      # TERM, grace period, then KILL.
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
