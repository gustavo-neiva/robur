# frozen_string_literal: true

require_relative "fleet/backoff"
require_relative "fleet/gate"
require_relative "fleet/render"
require_relative "fleet/roster"

module Robur
  # Fleet layer namespace (PLAN.fleet.md): one machine, many repos, forever.
  module Fleet
    module_function

    # Read-only board: why each roster repo will or will not run. No writes,
    # no spawns. This mapping is the seed of the one decision path the
    # planner (T2.1) will own — until then it is the only place verdicts
    # become actions.
    def dry_run(roster:, out:)
      rows = roster.entries.map do |e|
        g = Gate.new(e.path)
        n = g.open_tasks
        verdict =
          if e.parked           then "skip:parked"
          elsif !g.initialized? then "skip:no-conf"
          elsif n.zero?         then "skip:caught-up"
          else "run"
          end
        [File.basename(e.path), verdict, n]
      end
      out.puts Render.board(rows) unless rows.empty?
      0
    end
  end
end
