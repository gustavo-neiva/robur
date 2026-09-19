# frozen_string_literal: true

require_relative "fleet/gate"
require_relative "fleet/planner"
require_relative "fleet/render"
require_relative "fleet/roster"
require_relative "sys"

module Robur
  # Fleet layer namespace (PLAN.fleet.md): one machine, many repos, forever.
  module Fleet
    # The cycle's spend caps. The planner reads max_runs/max_plans; the field
    # set grows and the real reader (Fleet.budget, global conf + ENV) lands
    # in T2.4 — until then dry_run uses harbor's defaults.
    Budget = Struct.new(:max_runs, :max_plans, keyword_init: true)

    module_function

    # Read-only board: what the next cycle will do and why. The decisions
    # come from the ONE planner — this renders them, it decides nothing.
    # Parked rows are appended for visibility only (see Roster: the operator
    # must see what they turned off); the planner never decides for parked
    # repos because it walks roster.active.
    def dry_run(roster:, out:)
      gate_for = ->(repo) { Gate.new(repo) }
      planner = Planner.new(roster: roster, gate_for: gate_for,
                            budget: Budget.new(max_runs: 4, max_plans: 4),
                            clock: Sys::Clock.new) # ponytail: hardcoded defaults until T2.4's Fleet.budget
      rows = planner.decisions.map do |d|
        label = d.action == :skip ? "skip:#{d.reason.to_s.tr('_', '-')}" : d.action.to_s
        [File.basename(d.repo), label, gate_for.(d.repo).open_tasks]
      end
      roster.entries.select(&:parked).each do |e|
        rows << [File.basename(e.path), "skip:parked", gate_for.(e.path).open_tasks]
      end
      out.puts Render.board(rows) unless rows.empty?
      0
    end
  end
end
