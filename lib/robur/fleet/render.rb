# frozen_string_literal: true

require_relative "../fleet"

module Robur
  module Fleet
    # PURE terminal rendering of the fleet board. No IO, no clock, no disk.
    module Render
      module_function

      # rows: [[basename, verdict, open_count], ...] -> a string, one aligned
      # line per repo: `<basename>  <verdict>  <n> open`.
      def board(rows)
        w1 = rows.map { |r| r[0].to_s.length }.max.to_i
        w2 = rows.map { |r| r[1].to_s.length }.max.to_i
        rows.map { |name, verdict, n| "#{name.to_s.ljust(w1)}  #{verdict.to_s.ljust(w2)}  #{n} open" }
            .join("\n")
      end
    end
  end
end
