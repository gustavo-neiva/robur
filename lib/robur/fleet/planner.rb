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
    # it could want from the outside — the pause flag, the already-run set,
    # the time — is read by the CALLER and handed in as a value (`clock` is
    # the injected clock; its `now` drives the autoplan rate limit), and
    # gates arrive through the injected `gate_for` lambda. The stamp itself
    # is read on Gate (T2.2) and written only after a real plan turn (T3.5).
    class Planner
      Decision = Struct.new(:repo, :action, :reason, keyword_init: true)

      # Autoplan rate limit (T2.2): ENV/global-conf only, never a repo-conf
      # key. 6h — on a 15-minute beat an unstamped rule would draw 96 plan
      # turns a day per caught-up repo, and caught-up planning is the
      # estate's dominant cost line (harbor: 2,273 of 2,299 turns in four
      # days were a caught-up repo being "planned" for nothing).
      AUTOPLAN_MIN_SECS_DEFAULT = 21_600

      def initialize(roster:, gate_for:, budget:, clock:, paused: false, already_ran: [])
        @roster = roster
        @gate_for = gate_for
        @budget = budget
        @clock = clock
        @paused = paused
        @already_ran = already_ran
      end

      # Ordered: roster.active in file order. A :runnable verdict runs until
      # max_runs is spent, then skips with :max_runs; a caught-up repo with
      # a tracker emits ONE unattended plan turn per rate-limit window,
      # bounded by max_plans (T2.2); a repo run earlier this cycle skips
      # with :once_per_cycle (it costs no budget — it already spent its
      # own); every other verdict skips carrying the gate's reason — so a
      # backed-off, human-blocked or class-gated repo is never auto-planned.
      # Paused (T2.3): the CALLER stats the flag and hands it in; every
      # active repo skips with :paused, so cycle_plan spends nothing.
      def decisions
        if @paused
          return @roster.active.map { |e| Decision.new(repo: e.path, action: :skip, reason: :paused) }
        end

        runs = 0
        plans = 0
        min_secs = Integer(ENV.fetch("AUTOPLAN_MIN_SECS", AUTOPLAN_MIN_SECS_DEFAULT))
        @roster.active.filter_map do |entry|
          if @already_ran.include?(entry.path)
            Decision.new(repo: entry.path, action: :skip, reason: :once_per_cycle)
          else
            gate = @gate_for.(entry.path)
            verdict = gate.verdict
            if verdict == :runnable
              if runs < @budget.max_runs
                runs += 1
                Decision.new(repo: entry.path, action: :run, reason: verdict)
              else
                Decision.new(repo: entry.path, action: :skip, reason: :max_runs)
              end
            elsif verdict == :caught_up && gate.tracker?
              if !gate.autoplan_due?(min_secs, @clock.now)
                Decision.new(repo: entry.path, action: :skip, reason: :autoplan_recent)
              elsif plans < @budget.max_plans
                plans += 1
                Decision.new(repo: entry.path, action: :plan, reason: :caught_up)
              else
                Decision.new(repo: entry.path, action: :skip, reason: :max_plans)
              end
            else
              Decision.new(repo: entry.path, action: :skip, reason: verdict)
            end
          end
        end
      end

      # The cycle's spend, grouped off the ONE #decisions walk — never a
      # second decision path.
      def cycle_plan
        ds = decisions
        { runs: ds.select { |d| d.action == :run },
          plans: ds.select { |d| d.action == :plan } }
      end
    end
  end
end
