# frozen_string_literal: true

require "rbconfig"

require_relative "gate"

module Robur
  module Fleet
    # Executes a planner's cycle_plan (PLAN.fleet.md M3): it makes no
    # decisions of its own — the ONE decision path is Planner (constraint 5).
    # A separate process is still the right isolation boundary (one repo
    # crashing must not take the fleet down), but the child binary is
    # RESOLVED, never SEARCHED (constraint 6): shelling out to the bare name
    # `robur` gave three multi-day outages (2026-09-04..07) where launchd's
    # PATH resolved the shebang to system Ruby 2.6, and each was wrongly
    # charged to every repo as a run failure.
    class Cycle
      # The program is built from the LIVE process, not $0/$PROGRAM_NAME:
      # those differ under symlinks, binstubs and shims. This exact
      # expression is the one line design constraint 6 rests on.
      EXE = File.expand_path("../../../exe/robur", __dir__)

      # `system` returns NIL when the child never started and FALSE when it
      # ran and failed; only the nil case maps to the distinct sentinel
      # :spawn_error (T3.3 must not charge an environment fault to a repo).
      DEFAULT_SPAWNER = lambda do |argv|
        ran = system(*argv)
        ran.nil? ? nil : $?.exitstatus
      end

      # spawner is injected so no test ever launches a real turn. notifier
      # is nil until T5.3 wires the real Notifier; only its #notify_once is
      # called, so the wiring is literally passing the instance in.
      def initialize(planner:, spawner: DEFAULT_SPAWNER, lock: Lock,
                     notifier: nil, out: $stdout)
        @planner = planner
        @spawner = spawner
        @lock = lock
        @notifier = notifier
        @out = out
        @status = 0
        @human_skipped = []
      end

      # Launch one child turn for repo as
      # [RbConfig.ruby, EXE, *argv] — interpreter and program from this
      # process, never a name lookup. Returns the child's exit status, or
      # the sentinel :spawn_error when it could not be started at all.
      def spawn(repo, *argv)
        status = @spawner.([RbConfig.ruby, EXE, *argv])
        status.nil? ? :spawn_error : status
      end

      attr_reader :status, :human_skipped

      # The outcome policy (ported from harbor runner._run_repo): the
      # stop_reason the child left behind decides the repo's ladder.
      #   done          -> clear the backoff
      #   human_blocked -> repo is off for the rest of the cycle + notify
      #   stopped       -> neither bump nor clear: a human ran `robur stop`,
      #                    that is an instruction, not a failure — backing
      #                    off for it silently costs the next beat too
      #   gate_red / progress_stalled / review_exceeded -> bump
      #   anything else -> a real nonzero exit bumps; exit 0 changes nothing
      #   :spawn_error  -> bump NOTHING and fail the whole cycle loudly: a
      #                    child that never started is a property of this
      #                    machine, not of any repo
      # Returns one of :environment, :skipped, :cleared, :bumped, :no_change.
      def record_outcome(repo, exit_status)
        return fail_cycle(repo) if exit_status == :spawn_error

        reason = Gate.new(repo).stop_reason
        # human_blocked is deliberately NOT gated on a zero exit: the loop
        # itself exits 1 for it, so reason must win over exit status here.
        case reason
        when "human_blocked"
          @human_skipped << repo
          notify(repo, "human_blocked", "#{repo}: blocked on a human answer — off for this cycle")
          :skipped
        when "done", "stopped"
          # Trusted only on exit 0 — the loop exits 0 for exactly these, so
          # a real nonzero exit means the reason on disk is stale or merely
          # Gate's derived fallback, and the crash must bump, never clear
          # (a derived "done") and never cost nothing (a derived "stopped").
          if exit_status.zero?
            reason == "done" && Backoff.new(repo).clear! ? :cleared : :no_change
          else
            bump(repo)
          end
        when "gate_red"
          notify(repo, "gate_red", "#{repo}: gate red — backing off")
          bump(repo)
        when "progress_stalled", "review_exceeded"
          bump(repo)
        else
          # Unknown reason (stale "running" after a kill, "crashed"):
          # exit 0 changes nothing, a real nonzero exit bumps.
          exit_status.zero? ? :no_change : bump(repo)
        end
      end

      private

      def bump(repo)
        Backoff.new(repo).bump!
        :bumped
      end

      def notify(repo, key, msg)
        @notifier&.notify_once(repo, key, msg)
      end

      # A child that never started is this machine's fault (missing
      # interpreter or exe): charged to no repo's ladder, and loud.
      def fail_cycle(repo)
        @status = 1
        @out.puts "FATAL: #{repo}: child never started (:spawn_error) — "\
                  "environment fault, cycle failed, no repo backed off"
        :environment
      end
    end
  end
end
