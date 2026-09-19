# frozen_string_literal: true

require_relative "config"
require_relative "fleet/backoff"
require_relative "fleet/cycle"
require_relative "fleet/gate"
require_relative "fleet/lock"
require_relative "fleet/planner"
require_relative "fleet/render"
require_relative "fleet/roster"
require_relative "fleet/supervisor"
require_relative "paths"
require_relative "sys"

module Robur
  # Fleet layer namespace (PLAN.fleet.md): one machine, many repos, forever.
  module Fleet
    # The cycle's spend caps, read by Fleet.budget — the ONE resolver, with
    # precedence ENV > ~/.robur/conf (human-owned, bash-sourced, via
    # Config.load_global) > the declared defaults. All seven keys are
    # GLOBAL-ONLY (design constraint 4): never in Config::ALLOWLIST, never
    # read from a repo .robur.conf — an agent that could raise its own run
    # budget or lower its own backoff has escaped the thing that bounds it.
    Budget = Struct.new(:max_runs, :max_plans, :autoplan_min_secs,
                        :backoff_base, :backoff_cap, :interval,
                        :healthcheck_url, keyword_init: true)

    # field => [global key, declared default]. An Integer default marks the
    # field numeric; HEALTHCHECK_URL stays a string. The interval default is
    # the plan's 15-minute beat; the rest are harbor's / T2.2's.
    BUDGET_SOURCES = {
      max_runs:          ["MAX_RUNS_PER_CYCLE",  4],
      max_plans:         ["MAX_PLANS_PER_CYCLE", 4],
      autoplan_min_secs: ["AUTOPLAN_MIN_SECS",   Planner::AUTOPLAN_MIN_SECS_DEFAULT],
      backoff_base:      ["BACKOFF_BASE",        Backoff::BASE_DEFAULT],
      backoff_cap:       ["BACKOFF_CAP",         Backoff::CAP_DEFAULT],
      interval:          ["FLEET_INTERVAL",      900],
      healthcheck_url:   ["HEALTHCHECK_URL",     ""]
    }.freeze

    module_function

    # The world-read every planning surface shares (T3.4): the ONE base the
    # dry-run board and the real cycle both build their Planner from, so the
    # board can never disagree with what would actually run (constraint 5).
    def planner_base(roster)
      { roster: roster,
        gate_for: ->(repo) { Gate.new(repo) },
        budget: budget,
        clock: Sys::Clock.new,
        paused: File.exist?(Paths.fleet_paused_flag) }
    end

    # The real beat (T3.4): one full cycle over the roster — run, plan
    # top-up, run again — returning the cycle's status (0 green). Locking,
    # spawning and outcome recording belong to Cycle; this only assembles it
    # from the same base the board reads.
    def cycle(roster:, out: $stdout)
      cycle_runner(roster: roster, out: out).run
    end

    # The runner OBJECT behind cycle — the supervisor (T5.1) beats on the
    # same assembly repeatedly instead of running it once.
    def cycle_runner(roster:, out: $stdout)
      Cycle.new(**planner_base(roster), out: out)
    end

    # Resolve the fleet budgets. A missing (or unreadable) conf yields the
    # defaults, never an exception; a value that does not parse as a number
    # falls back to its default rather than killing the beat.
    def budget
      global = File.file?(Paths.global_conf) ? Config.load_global(Paths.global_conf)
                                             : { values: {}, env: {} }
      kw = BUDGET_SOURCES.to_h do |field, (key, default)|
        raw = ENV[key] || global[:env][key] || global[:values][key]
        value = if raw.nil? || raw.empty?
                  default
                elsif default.is_a?(Integer)
                  begin
                    Integer(raw, 10)
                  rescue ArgumentError
                    default
                  end
                else
                  raw
                end
        [field, value]
      end
      Budget.new(**kw)
    end

    # Read-only board: what the next cycle will do and why. The decisions
    # come from the ONE planner — this renders them, it decides nothing.
    # Parked rows are appended for visibility only (see Roster: the operator
    # must see what they turned off); the planner never decides for parked
    # repos because it walks roster.active.
    def dry_run(roster:, out:)
      base = planner_base(roster)
      gate_for = base[:gate_for]
      paused = base[:paused]
      # The pause is announced once in the header, not repeated per row.
      rows = Planner.new(**base).decisions.map do |d|
        label = d.action == :skip ? (paused ? "skip" : "skip:#{d.reason.to_s.tr('_', '-')}") : d.action.to_s
        [File.basename(d.repo), label, gate_for.(d.repo).open_tasks]
      end
      roster.entries.select(&:parked).each do |e|
        rows << [File.basename(e.path), "skip:parked", gate_for.(e.path).open_tasks]
      end
      out.puts "fleet paused" if paused
      out.puts Render.board(rows) unless rows.empty?
      0
    end
  end
end
