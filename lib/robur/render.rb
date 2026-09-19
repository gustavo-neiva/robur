# frozen_string_literal: true

module Robur
  # Pure terminal rendering — no file I/O, no globals beyond the stdout-tty
  # check — so everything here is testable with no agent and no live loop.
  module Render
    module_function

    FILL = "\u2593" # ▓
    EMPTY = "\u2591" # ░

    def bar(pct, width)
      pct = pct.to_i.clamp(0, 100)
      fill = pct * width / 100
      (FILL * fill) + (EMPTY * (width - fill))
    end

    def ansi_ok?
      $stdout.tty? && ENV["NO_COLOR"].to_s.empty?
    end

    # Self-resetting SGR: styles never carry across lines.
    def color(code, text)
      ansi_ok? ? "\e[#{code}m#{text}\e[0m" : text.to_s
    end

    def c_bold(text) = color("1", text)
    def c_dim(text) = color("2", text)
    def c_green(text) = color("32", text)
    def c_blue(text) = color("34", text)
    def c_purple(text) = color("35", text)

    def summary(text, nlines = 4)
      text.to_s.lines(chomp: true).reject { |l| l.strip.empty? }.last(nlines).join("\n")
    end

    def fmt_dur(secs)
      secs = secs.to_i
      return "#{secs}s" if secs < 60
      return "#{secs / 60}m" if secs < 3600

      "#{secs / 3600}h#{(secs % 3600) / 60}m"
    end

    # "ETA unknown" before any recorded turn duration — honest, not a guess.
    def eta(remaining, avg)
      return "ETA unknown" if avg.to_i.zero?

      "~#{remaining} turns / ~#{fmt_dur(remaining.to_i * avg.to_i)} left"
    end

    def timing(turn, elapsed, avg, remaining)
      "  \u23F1 turn #{turn} \u00B7 #{fmt_dur(elapsed)}   avg #{fmt_dur(avg)}   #{eta(remaining, avg)}"
    end

    # The two-line live PM header printed each turn (terminal only, never
    # logged):
    #   Step D/T  [bar PCT%]   Mname  (mdone/mtotal)
    #     ▶ TASKID  TASKTEXT   tier · model
    def status_block(done, total, mname, mdone, mtotal, turn, tier, model, taskid, tasktext)
      _ = turn # unused in the rendered text; kept so callers pass a full turn context
      pct = total.to_i.positive? ? done.to_i * 100 / total.to_i : 0
      line1 = +"Step #{done}/#{total}  [#{bar(pct, 12)} #{pct}%]"
      line1 << "   #{mname}  (#{mdone}/#{mtotal})" unless mname.to_s.empty?
      line2 = "  \u25B6 #{taskid}  #{tasktext}   #{tier} \u00B7 #{model}"
      "#{line1}\n#{line2}\n"
    end
  end
end
