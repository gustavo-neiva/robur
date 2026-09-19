# frozen_string_literal: true

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
        v = g.verdict
        verdict = e.parked ? "skip:parked" : (v == :runnable ? "run" : "skip:#{v.to_s.tr('_', '-')}")
        [File.basename(e.path), verdict, g.open_tasks]
      end
      out.puts Render.board(rows) unless rows.empty?
      0
    end
  end
end
