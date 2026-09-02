# frozen_string_literal: true

module Robur
  # Pure terminal rendering (ratchet/lib/render.sh port): progress bars, ANSI
  # color wrapping, duration/ETA formatting, the PM turn header. All
  # functions are PURE — no file I/O, no globals beyond the stdout-tty check
  # `ansi_ok?` needs — so they're testable with no agent and no live loop.
  module Render
    module_function

    FILL = "\u2593" # ▓
    EMPTY = "\u2591" # ░

    # bar(pct, width) -> "▓▓▓░░░", pct clamped to 0-100, integer math only.
    def bar(pct, width)
      pct = pct.to_i.clamp(0, 100)
      fill = pct * width / 100
      (FILL * fill) + (EMPTY * (width - fill))
    end

    # ansi_ok? -> stdout is a TTY AND NO_COLOR is unset. Callers gate color
    # emit on this.
    def ansi_ok?
      $stdout.tty? && ENV["NO_COLOR"].to_s.empty?
    end

    # color(code, text) -> SGR-wrapped when ansi_ok?, else passthrough.
    # Self-resetting: styles never carry across lines.
    def color(code, text)
      ansi_ok? ? "\e[#{code}m#{text}\e[0m" : text.to_s
    end

    def c_bold(text) = color("1", text)
    def c_dim(text) = color("2", text)
    def c_green(text) = color("32", text)
    def c_blue(text) = color("34", text)
    def c_purple(text) = color("35", text)

    # activity(event_type) -> human verb for a pi json stream event.
    def activity(event_type)
      case event_type
      when "turn_start" then "thinking"
      when "tool_execution_update" then "working"
      when "tool_call", "toolCall" then "running a tool"
      else event_type.to_s.empty? ? "working" : event_type
      end
    end

    # summary(text, nlines=4) -> drops blank lines, keeps the last NLINES.
    def summary(text, nlines = 4)
      text.to_s.lines(chomp: true).reject { |l| l.strip.empty? }.last(nlines).join("\n")
    end

    # fmt_dur(secs) -> human duration: "42s", "57m", "1h20m".
    def fmt_dur(secs)
      secs = secs.to_i
      return "#{secs}s" if secs < 60
      return "#{secs / 60}m" if secs < 3600

      "#{secs / 3600}h#{(secs % 3600) / 60}m"
    end

    # eta(remaining, avg) -> "~19 turns / ~57m left", or the honestly-labelled
    # "ETA unknown" before any recorded turn duration.
    def eta(remaining, avg)
      return "ETA unknown" if avg.to_i.zero?

      "~#{remaining} turns / ~#{fmt_dur(remaining.to_i * avg.to_i)} left"
    end

    # timing(turn, elapsed, avg, remaining) -> "  ⏱ turn N · dur   avg dur   eta"
    def timing(turn, elapsed, avg, remaining)
      "  \u23F1 turn #{turn} \u00B7 #{fmt_dur(elapsed)}   avg #{fmt_dur(avg)}   #{eta(remaining, avg)}"
    end

    # status_block(...) -> the two-line live PM header bin/ratchet prints
    # each turn (term_only, never logged):
    #   Step D/T  [bar PCT%]   Mname  (mdone/mtotal)
    #     ▶ TASKID  TASKTEXT   tier · model
    def status_block(done, total, mname, mdone, mtotal, turn, tier, model, taskid, tasktext)
      _ = turn # bash's positional arg 6; unused in the rendered text, kept for signature parity
      pct = total.to_i.positive? ? done.to_i * 100 / total.to_i : 0
      line1 = +"Step #{done}/#{total}  [#{bar(pct, 12)} #{pct}%]"
      line1 << "   #{mname}  (#{mdone}/#{mtotal})" unless mname.to_s.empty?
      line2 = "  \u25B6 #{taskid}  #{tasktext}   #{tier} \u00B7 #{model}"
      "#{line1}\n#{line2}\n"
    end
  end
end
