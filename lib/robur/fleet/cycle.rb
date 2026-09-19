# frozen_string_literal: true

require "rbconfig"

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

      # spawner is injected so no test ever launches a real turn.
      def initialize(planner:, spawner: DEFAULT_SPAWNER, lock: Lock, out: $stdout)
        @planner = planner
        @spawner = spawner
        @lock = lock
        @out = out
      end

      # Launch one child turn for repo as
      # [RbConfig.ruby, EXE, *argv] — interpreter and program from this
      # process, never a name lookup. Returns the child's exit status, or
      # the sentinel :spawn_error when it could not be started at all.
      def spawn(repo, *argv)
        status = @spawner.([RbConfig.ruby, EXE, *argv])
        status.nil? ? :spawn_error : status
      end
    end
  end
end
