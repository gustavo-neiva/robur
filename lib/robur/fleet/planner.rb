# frozen_string_literal: true

require_relative "../fleet"

module Robur
  module Fleet
    # PURE: roster + gate verdicts + budgets -> [Decision]. The ONE decision
    # path shared by `--dry-run` and the real cycle (design constraint 5):
    # harbor's two paths (`run_cycle` vs `dry_run_lines`, whose string output
    # `eligibility` re-parsed) drifted apart exactly here, and the board then
    # reported `0 open` for repos the runner considered runnable.
    #
    # The planner never touches disk, the clock or a subprocess: every value
    # it could want from the outside — the pause flag, the already-run set —
    # is read by the CALLER and handed in as a value, and gates arrive
    # through the injected `gate_for` lambda. `paused` is honoured in T2.3,
    # `clock` in T2.2 (autoplan rate limit); declared now so this signature
    # never grows an fs: later.
    class Planner
      Decision = Struct.new(:repo, :action, :reason, keyword_init: true)

      def initialize(roster:, gate_for:, budget:, clock:, paused: false, already_ran: [])
        @roster = roster
        @gate_for = gate_for
        @budget = budget
        @clock = clock
        @paused = paused
        @already_ran = already_ran
      end

      # Ordered: roster.active in file order. A :runnable verdict runs until
      # max_runs is spent, then skips with :max_runs; a repo run earlier this
      # cycle skips with :once_per_cycle (it costs no budget — it already
      # spent its own); every other verdict skips carrying the gate's reason.
      def decisions
        runs = 0
        @roster.active.filter_map do |entry|
          if @already_ran.include?(entry.path)
            Decision.new(repo: entry.path, action: :skip, reason: :once_per_cycle)
          else
            verdict = @gate_for.(entry.path).verdict
            if verdict == :runnable && runs < @budget.max_runs
              runs += 1
              Decision.new(repo: entry.path, action: :run, reason: verdict)
            else
              Decision.new(repo: entry.path, action: :skip,
                           reason: verdict == :runnable ? :max_runs : verdict)
            end
          end
        end
      end
    end
  end
end
