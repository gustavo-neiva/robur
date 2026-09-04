# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "sys"

module Robur
  # loop.log is a RENDERING of events.jsonl, not free-form prose parsed back
  # with regexes (port of the emit lines in ratchet/bin/ratchet +
  # ratchet/lib/commit-gate.sh). Each emit call appends one JSON record with
  # the exact fields that produced the human line, so a metric never breaks
  # because someone reworded a log line.
  class Observability
    Event = Struct.new(:kind, :ts, :fields, keyword_init: true)

    # kind => fields hash -> array of human lines, in the exact bash wording.
    RENDER = {
      turn_start: lambda { |f|
        ["--- turn #{f[:turn]} | model=#{f[:model]} ---",
         "turn #{f[:turn]} | tier=#{f[:tier]} | model=#{f[:model]} | " \
         "thinking=#{f[:thinking]} | task=#{f[:task]}"]
      },
      turn_end: lambda { |f|
        ["turn #{f[:turn]} end | class=#{f[:class]} | took=#{f[:took]}s | " \
         "exitcode=#{f[:exitcode]} | task=#{f[:task]}"]
      },
      commit: ->(f) { ["  committed: #{f[:subject]}"] },
      bench: lambda { |f|
        ["ALL models benched (exhausted), attempt #{f[:attempt]}. " \
         "Sleeping #{f[:backoff]}s, then reset + retry."]
      },
      stop: ->(f) { ["ratchet END after #{f[:turns]} turn(s)."] },
      run_end: ->(f) { ["ratchet END after #{f[:turns]} turn(s)."] },
      human: ->(f) { ["HUMAN NEEDED: #{f[:msg]}"] },
      # run_start reproduces Loop.run's startup banner verbatim (loop.rb:61-75).
      # session is the full "name (resume=x)" string; commit/push/pr render
      # yes/no the way loop.rb renders conf "1"/other.
      run_start: lambda { |f|
        yn = ->(v) { (v == "1" || v == true) ? "yes" : "no" }
        ["=" * 60,
         "ratchet START",
         "  repo      : #{f[:repo]}",
         "  session   : #{f[:session]}",
         "  tracker   : #{f[:tracker]}",
         "  models    : #{f[:models].join(" ")}  (preference order, fallback chain)",
         "  turn cap  : #{f[:turn_timeout]}s   cooldown: #{f[:cooldown]}s   both-wait: #{f[:both_wait]}s",
         "  tokens    : step='#{f[:step_token]}'  done='#{f[:done_token]}'",
         "  agent     : #{f[:agent_cmd]}",
         "  thinking  : #{f[:thinking].to_s.empty? ? "inherit" : f[:thinking]}",
         "  verify    : #{f[:verify_cmd].to_s.empty? ? "<EMPTY — loud warning, no gate>" : f[:verify_cmd]}",
         "  commit    : per-turn=#{yn.call(f[:commit_each_turn])}  " \
         "push-on-done=#{yn.call(f[:push_on_done])}  pr=#{yn.call(f[:open_pr])}",
         "  loop log  : #{f[:log_dir]}/loop.log",
         "  stop      : Ctrl-C",
         "=" * 60]
      },
      model_selected: ->(f) { ["  model #{f[:model]} selected (#{f[:reason]})"] },
      model_benched: ->(f) { ["  model #{f[:model]} benched for #{f[:seconds]}s (#{f[:reason]})"] },
      gate_result: ->(f) { ["  gate: #{f[:status]} (#{f[:reason]})"] },
      progress_stall: ->(f) { ["  progress stalled #{f[:stalls]}x — #{f[:action]}"] },
      task_blocked: ->(f) { ["  task #{f[:task]} blocked after #{f[:stalls]} stall(s)"] },
      tokens: lambda { |f|
        ["  tokens: in=#{f[:input].to_i + f[:cache_read].to_i + f[:cache_write].to_i} " \
         "fresh=#{f[:input].to_i + f[:cache_write].to_i} " \
         "out=#{f[:output]} cache_r=#{f[:cache_read]} msgs=#{f[:messages]} " \
         "cost=$#{format('%.6f', f[:cost])}"]
      },
    }.freeze

    DEFAULT_CHEAP_MODEL = "<first-model>"

    # Round-trip ceiling for one turn. `messages` is the deduped per-message
    # usage count, i.e. how many times the agent went back to the model
    # inside a single turn. Healthy turns measured 6; the production runaway
    # logged ~1,100 and burned 20,014,294 prompt-side tokens to emit 716
    # output ones before timing out. 200 sits an order of magnitude above
    # normal and an order below the pathology. Tuned via ENV, not
    # .ratchet.conf: the conf allowlist is a frozen contract (bash `doctor`
    # rejects unknown keys), and SUMMARY_LINES/POLL_INTERVAL already set the
    # ENV-knob precedent.
    RUNAWAY_MESSAGES_DEFAULT = 200

    def self.runaway_messages
      v = ENV["RATCHET_RUNAWAY_MESSAGES"].to_i
      v.positive? ? v : RUNAWAY_MESSAGES_DEFAULT
    end

    # True when a turn's round-trip count crosses the ceiling. Callers log it
    # and carry `runaway` on the :tokens event so the condition is queryable
    # after the fact instead of being reconstructed from a prose line.
    def self.runaway?(detail)
      detail[:messages].to_i >= runaway_messages
    end

    def initialize(dir, clock: Sys::Clock.new)
      @loop_log = File.join(dir, "loop.log")
      @events_log = File.join(dir, "events.jsonl")
      @clock = clock
    end

    # emit(:turn_start, turn: 3, model: "m", tier: "build", thinking: "off", task: "T1")
    # -> appends the rendered line(s) to loop.log and one JSON record to
    # events.jsonl, and returns the Event.
    def emit(kind, **fields)
      lines = RENDER.fetch(kind).call(fields)
      ts = @clock.now.strftime("%Y-%m-%d %H:%M:%S")
      append(@loop_log, lines.map { |l| "[#{ts}] #{l}" }.join("\n") + "\n")
      append(@events_log, JSON.generate({ kind: kind.to_s, ts: ts }.merge(fields)) + "\n")
      Event.new(kind: kind, ts: ts, fields: fields)
    end

    # emit_event — telemetry with no frozen human line (tokens, model picks):
    # ONE JSON record to events.jsonl ONLY, never loop.log. Records carry
    # "v": 1 so a future field rename can be detected downstream.
    def emit_event(kind, **fields)
      ts = @clock.now.strftime("%Y-%m-%d %H:%M:%S")
      append(@events_log, JSON.generate({ kind: kind.to_s, ts: ts, v: 1 }.merge(fields)) + "\n")
      Event.new(kind: kind, ts: ts, fields: fields)
    end

    # notify_human MSG -> surface a message a human must act on (observability.sh:17).
    # Emits "HUMAN NEEDED: MSG", rings the terminal bell when stderr is a TTY,
    # and runs NOTIFY_CMD in the background (never blocks the caller) with MSG
    # as $1. SECURITY: NOTIFY_CMD is only ever taken from ENV/the explicit
    # argument here — this method never reads a conf file itself, so a repo
    # .ratchet.conf (agent-writable, PARSED not sourced per T2.2) can never
    # reach it; only the trusted, bash-sourced global conf may set it.
    def notify_human(msg, notify_cmd: ENV["NOTIFY_CMD"])
      emit(:human, msg: msg)
      $stderr.write("\a") if $stderr.tty?
      return if notify_cmd.to_s.empty?

      pid = Process.spawn("sh", "-c", "#{notify_cmd} \"$1\"", "_", msg)
      Process.detach(pid)
      nil
    end

    # RATCHET_HOME (observability.sh:14): never $HOME directly — metrics_append
    # honours the override so isolating RATCHET_HOME (tests, selftest) never
    # leaks a row into the real ~/.ratchet/metrics.tsv.
    def self.ratchet_home
      ENV["RATCHET_HOME"] || File.join(ENV["HOME"], ".ratchet")
    end

    # metrics_append (observability.sh:239): EVENT TURN TIER MODEL CLASS TOOK
    # TASK TOKIN TOKOUT COST -> one 12-column TSV row. Best-effort: never
    # raises, matching the bash `|| true`.
    #
    # `usage:` appends the three EXTENSION columns 13-15 (fresh_in,
    # cache_read, messages) and is omitted by default, so every existing
    # caller still writes exactly the 12 frozen columns. See
    # METRICS_EXTENSION_COLUMNS for why they exist.
    def metrics_append(repo_dir, event, turn, tier, model, klass, took, task, tok_in, tok_out, cost,
                       usage: nil)
      f = ENV["RATCHET_METRICS"] || File.join(self.class.ratchet_home, "metrics.tsv")
      FileUtils.mkdir_p(File.dirname(f))
      row = [@clock.now.strftime("%F %T"), File.basename(repo_dir), event, turn, tier, model,
             klass, took, task, tok_in, tok_out, cost]
      row.concat(self.class.extension_columns(usage)) if usage
      append(f, "#{row.join("\t")}\n")
      nil
    rescue StandardError
      nil
    end

    # Columns 13-15, appended past the frozen 12. tin (column 10) is
    # input+cache_read+cache_write and is dominated by cache_read — a real
    # production turn measured input=3,565 cache_read=2,555,904, so tin says
    # "2.5M tokens" about a turn that consumed 3.5k fresh ones. Without these
    # three, a bloated prompt and a cheap turn with many cached round-trips
    # are indistinguishable after the fact:
    #   fresh_in   — input + cache_write, the tokens actually paid for at
    #                full rate; the number that moves when a prompt bloats.
    #   cache_read — split out so tin stays reconstructible (tin =
    #                fresh_in + cache_read) and cache hit rate is derivable.
    #   messages   — deduped per-message usage events = agent round-trips.
    #                The runaway signal: one production turn logged ~1,100.
    # Bash writes 12 columns and reads none past them, so this is additive
    # only; the differential harness compares the first 12 (see
    # test/differential/harness.rb#split_metrics_rows).
    METRICS_EXTENSION_COLUMNS = %w[fresh_in cache_read messages].freeze

    def self.extension_columns(usage)
      u = usage || {}
      [u[:input].to_i + u[:cache_write].to_i, u[:cache_read].to_i, u[:messages].to_i]
    end

    # _turn_usage FILE -> "in\tout\tcost" (observability.sh:215): per-message
    # usage is a DELTA, never cumulative, so sum (not max) is the only correct
    # aggregate. The `in` column is input + cacheRead + cacheWrite (total
    # prompt-side tokens moved) — deliberate divergence from bash _turn_usage:
    # real usage events carry cacheRead ~1300x input, so bash's number was
    # 50-100x low; the cache fields didn't exist when it was written.
    def self.turn_usage(path)
      return "0\t0\t0" unless File.file?(path)

      d = turn_usage_detail(path)
      format("%d\t%d\t%.6f", d[:input] + d[:cache_read] + d[:cache_write], d[:output], d[:cost])
    end

    # turn_usage_detail PATH -> {input, output, cache_read, cache_write,
    # reasoning, cost, messages}: the same places turn_usage reads, summed
    # over deduped per-message usage events. messages is the deduped event
    # count — the runaway-turn signal (one real turn logged ~1,100
    # round-trips). Missing file -> all zeros, never raises.
    def self.turn_usage_detail(path)
      last = {}
      Sys.read_scrubbed(path).to_s.each_line do |line|
        ev = begin
          JSON.parse(line)
        rescue JSON::ParserError, ArgumentError
          next
        end
        msg = ev["message"] || {}
        u = ev["usage"] || msg["usage"]
        next if u.nil?

        # Dedupe by id/message.id/message.responseId/responseId — zai streams
        # carry no id and repeat the same usage 3-6x per message; last wins so
        # an early zero-usage event never wins over the real one (this is the
        # collapse that makes the all-zero event flood count once).
        # ponytail: dedupe falls back to the raw line, so byte-identical
        # DISTINCT messages collapse too; upgrade path = a real per-message id
        # from the agent.
        key = ev["id"] || msg["id"] || msg["responseId"] || ev["responseId"] || line
        last[key] = [u["input"] || 0, u["output"] || 0, u["cacheRead"] || 0, u["cacheWrite"] || 0,
                     u["reasoning"] || 0, (u["cost"] || {})["total"] || 0.0]
      end
      sums = [0, 0, 0, 0, 0, 0.0]
      last.each_value { |v| v.each_with_index { |x, i| sums[i] += x } }
      { input: sums[0], output: sums[1], cache_read: sums[2], cache_write: sums[3],
        reasoning: sums[4], cost: sums[5], messages: last.size }
    rescue Errno::ENOENT
      { input: 0, output: 0, cache_read: 0, cache_write: 0, reasoning: 0, cost: 0.0, messages: 0 }
    end

    # avg_turn_secs LOGFILE -> mean turn duration in seconds from took= lines
    # (observability.sh:118). 0 when the file is missing or has no took= line —
    # the "before any recorded duration" case render_eta/ETA renders honestly.
    def self.avg_turn_secs(logfile)
      return 0 unless File.file?(logfile)

      sum = 0
      count = 0
      Sys.read_scrubbed(logfile).to_s.each_line do |line|
        s = line[/took=(\d+)s/, 1]
        next unless s

        sum += s.to_i
        count += 1
      end
      count.positive? ? sum / count : 0
    end

    # stats DIR -> baseline metrics text (observability.sh:132 cmd_stats).
    # Prefers DIR/events.jsonl (structured `class=` on turn_end, no prose
    # regex) and falls back to DIR/loop.log so pre-robur logs still report;
    # both feed the SAME renderer, so the two sources can never drift in
    # wording. ponytail: the events path counts review/milestone verdicts and
    # deadline-kill wall-hours as zero — no CommitGate/watchdog event carries
    # them yet — add those RENDER kinds and this starts counting them for free.
    def self.stats(dir, cheap_model: DEFAULT_CHEAP_MODEL)
      events_path = File.join(dir, "events.jsonl")
      loop_log = File.join(dir, "loop.log")
      # The two paths do NOT measure the same things — the loop.log regex
      # path cannot see review verdicts, deadline-kill wall-hours, or
      # anything token-shaped — so a silent fallback makes a degraded report
      # look authoritative. `stats_source` names which one ran; the audit
      # found events.jsonl had never been written in production, i.e. every
      # `stats` ever run took the legacy path without saying so.
      metrics = if File.file?(events_path)
                  stats_from_events(events_path, cheap_model)
                else
                  raise "no loop.log found at #{loop_log} (nothing run here yet?)" unless File.file?(loop_log)

                  stats_from_loop_log(loop_log, cheap_model)
                end
      # NOTE: the returned block stays byte-identical to bash cmd_stats — the
      # parity test asserts that. The source line is a separate surface the
      # CLI prints alongside it (stats_source).
      render_stats(metrics, cheap_model)
    end

    # Which of the two adapters `stats` would use for DIR, as a human line.
    # Kept out of `stats` itself so the rendered block stays bash-identical.
    def self.stats_source(dir)
      if File.file?(File.join(dir, "events.jsonl"))
        "events.jsonl"
      else
        "loop.log (legacy — no events.jsonl here; token and review metrics unavailable)"
      end
    end

    def self.blank_stats
      { turns: 0, cheap: 0, steps: 0, dones: 0, hard: 0, transient: 0, timeout: 0, exhausted: 0,
        empty: 0,
        dl_kills: 0, wasted: 0.0, tier_counts: Hash.new(0), model_counts: Hash.new(0), durations: [],
        review_pass: 0, review_fail: 0, milestone_complete: 0 }
    end
    private_class_method :blank_stats

    # events.jsonl adapter: turn_start already carries tier+model together (one
    # record replaces bash's two separate log lines), and turn_end's `class`
    # field IS the outcome classification, so no substring matching is needed.
    def self.stats_from_events(path, cheap_model)
      m = blank_stats
      bench_ts = nil
      Sys.read_scrubbed(path).to_s.each_line do |line|
        ev = JSON.parse(line)
        ts = Time.strptime(ev["ts"], "%Y-%m-%d %H:%M:%S")
        case ev["kind"]
        when "turn_start"
          m[:turns] += 1
          m[:cheap] += 1 if ev["model"] == cheap_model
          m[:tier_counts][ev["tier"]] += 1 if ev["tier"]
          m[:model_counts][ev["model"]] += 1 if ev["model"]
          if bench_ts
            m[:wasted] += ts - bench_ts
            bench_ts = nil
          end
        when "turn_end"
          m[:durations] << ev["took"].to_i if ev["took"]
          case ev["class"]
          when "step" then m[:steps] += 1
          when "done" then m[:dones] += 1
          when "hard" then m[:hard] += 1
          when "transient" then m[:transient] += 1
          when "timeout" then m[:timeout] += 1
          when "exhausted" then m[:exhausted] += 1
          when "empty" then m[:empty] += 1
          end
        when "bench"
          bench_ts = ts
        end
      rescue JSON::ParserError, ArgumentError
        next
      end
      m
    end
    private_class_method :stats_from_events

    # loop.log adapter — a faithful Ruby port of cmd_stats' python regexes
    # (observability.sh:136), unchanged so it still reports on logs a bash
    # ratchet run left behind.
    def self.stats_from_loop_log(path, cheap_model)
      m = blank_stats
      ts_re = /\A\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (.*)\z/
      turn_re = /\A--- turn \d+ \| model=(\S+) ---\z/
      tier_re = /\Aturn \d+ \| tier=(\S+) \| model=(\S+) \| thinking=\S+\z/
      took_re = /turn \d+ end \| class=\S+ \| took=(\d+)s/
      bench_ts = nil
      cur_ts = nil
      Sys.read_scrubbed(path).to_s.each_line do |raw|
        md = ts_re.match(raw.chomp)
        next unless md

        ts = Time.strptime(md[1], "%Y-%m-%d %H:%M:%S")
        rest = md[2]
        if (tm = turn_re.match(rest))
          m[:turns] += 1
          m[:cheap] += 1 if tm[1] == cheap_model
          if bench_ts
            m[:wasted] += ts - bench_ts
            bench_ts = nil
          end
          cur_ts = ts
        elsif (tr = tier_re.match(rest))
          m[:tier_counts][tr[1]] += 1
          m[:model_counts][tr[2]] += 1
        elsif (tk = took_re.match(rest))
          m[:durations] << tk[1].to_i
        elsif rest.include?("terminating") && rest.include?("deadline")
          m[:dl_kills] += 1
          m[:wasted] += ts - cur_ts if cur_ts
        elsif rest.include?("review-pass")
          m[:review_pass] += 1
        elsif rest.include?("review-fail")
          m[:review_fail] += 1
        elsif rest.include?("milestone-complete")
          m[:milestone_complete] += 1
        elsif rest.include?("step complete")
          m[:steps] += 1
        elsif rest.start_with?("agent signaled")
          m[:dones] += 1
        elsif rest.include?("EXHAUSTED")
          m[:exhausted] += 1
        elsif rest.include?("HARD ERROR")
          m[:hard] += 1
        elsif rest.start_with?("model ") && rest.include?("TIMEOUT (")
          m[:timeout] += 1
        elsif rest.include?("transient failure")
          m[:transient] += 1
        elsif rest.start_with?("ALL models benched")
          bench_ts = ts
        end
      end
      m
    end
    private_class_method :stats_from_loop_log

    # Same wording/order as bash cmd_stats' python f-strings, for either source.
    def self.render_stats(m, cheap_model)
      succ = m[:steps] + m[:dones]
      att = succ + m[:hard] + m[:transient] + m[:timeout]
      sr = att.positive? ? succ.to_f / att * 100.0 : 0.0
      wh = m[:wasted] / 3600.0
      wp = m[:turns].positive? ? wh / m[:turns] * 100.0 : 0.0
      cp = m[:turns].positive? ? m[:cheap].to_f / m[:turns] * 100.0 : 0.0

      lines = []
      lines << "turns started         : #{m[:turns]}"
      lines << "  on cheap (#{cheap_model}): #{m[:cheap]} (#{format('%.0f', cp)}%)"
      lines << "successes (step+done) : #{succ}  (steps=#{m[:steps]} done=#{m[:dones]})"
      lines << "failures              : hard=#{m[:hard]} transient=#{m[:transient]} " \
               "timeout=#{m[:timeout]} exhausted=#{m[:exhausted]} empty=#{m[:empty]}"
      lines << "step-success rate     : #{format('%.0f', sr)}%"
      lines << "deadline kills        : #{m[:dl_kills]}"
      lines << "wasted wall-hours     : #{format('%.2f', wh)}h  (#{format('%.2f', wp)}h per 100 turns)"
      if m[:tier_counts].any?
        lines << "turns by tier         : #{m[:tier_counts].sort.map { |k, v| "#{k}=#{v}" }.join(', ')}"
      end
      if m[:model_counts].any?
        lines << "turns by model        : #{m[:model_counts].sort.map { |k, v| "#{k}=#{v}" }.join(', ')}"
      end
      if m[:durations].any?
        avg = m[:durations].sum.to_f / m[:durations].size
        lines << "turn duration         : avg=#{format('%.0f', avg)}s max=#{m[:durations].max}s"
      end
      if m[:milestone_complete].positive? || m[:review_pass].positive? || m[:review_fail].positive?
        lines << "milestones completed  : #{m[:milestone_complete]}"
        lines << "review verdicts       : pass=#{m[:review_pass]} fail=#{m[:review_fail]}"
      end
      lines.join("\n")
    end
    private_class_method :render_stats

    private

    def append(path, text)
      File.open(path, "a") { |f| f.write(text) }
    end
  end
end
