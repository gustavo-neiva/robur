# frozen_string_literal: true

require_relative "../fleet"
require_relative "../render"

module Robur
  module Fleet
    # PURE terminal rendering of the fleet board. No IO, no clock, no disk.
    module Render
      module_function

      # The whole-fleet board (T6.1): one aligned line per roster entry —
      # name, verdict, open/total, backoff expiry as a RELATIVE duration,
      # stop reason, lock — then a `waiting on you` section. Pure: rows
      # arrive pre-measured, only layout and house colour happen here.
      #   row:     [name, verdict, open, total, backoff_secs_or_nil, stop, locked]
      #   waiting: [[name, task_id, question_or_nil], ...]
      def status(rows, waiting)
        w = rows.map { |r| r[0].to_s.length }.max.to_i
        wc = rows.map { |r| "#{r[2]}/#{r[3]}".length }.max
        ws = rows.map { |r| r[5].to_s.length }.max
        lines = rows.map do |name, verdict, open, total, backoff, stop, locked|
          counts = "#{open}/#{total}".ljust(wc)
          "#{name.to_s.ljust(w)}  #{verdict.to_s.ljust(14)}  #{counts}  " \
            "#{backoff ? Robur::Render.c_blue("in #{Robur::Render.fmt_dur(backoff)}") : Robur::Render.c_dim('-')}  " \
            "#{stop.to_s.ljust(ws)}  #{locked ? Robur::Render.c_bold('locked') : '-'}"
        end
        return lines.join("\n") if waiting.empty?

        (lines + ["", Robur::Render.c_bold("waiting on you")] + waiting.map do |name, id, question|
          "  #{name.to_s.ljust(w)}  #{id || '?'}  #{question || '-'}"
        end).join("\n")
      end

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
