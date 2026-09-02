# frozen_string_literal: true

require "optparse"
require "fileutils"
require "robur/config"
require "robur/loop"
require "robur/plan"
require "robur/tier"
require "robur/model_chain"
require "robur/turn"
require "robur/classifier"
require "robur/commit_gate"
require "robur/render"
require "robur/observability"
require "robur/state"

module Robur
  # CLI surfaces ported so far: --help, unknown-flag, doctor. Differential
  # parity means output must match the bash baseline BYTE FOR BYTE (after the
  # harness's narrow normalization), so the program name and all wording below
  # are frozen contract text, copied from ratchet's usage()/cmd_doctor().
  module CLI
    PROG = "ratchet" # differential parity: baseline prints "ratchet", not "robur"

    HELP_BODY = <<~USAGE
      Usage: #{PROG} <command> [REPO_DIR] [OPTIONS]

      #{PROG} — an unattended-but-safe agent loop. Runs a headless coding agent
      (pi, or any -p-style CLI) ONE turn at a time against a repo, surviving provider
      rate limits, gating every commit on a green test suite, and routing shared-state
      actions (push, PR/MR) through a human. A RED tree is never committed.

      Commands:
        run    [REPO]   Run the loop unattended until the agent prints ALL_DONE. (default)
        once   [REPO]   Run exactly one turn, then exit (testing/debugging).
        init   [REPO]   Stamp AGENTS.md protocol + .ratchet.conf + seed PLAN.md (existing repo).
        new    "<idea>" Scaffold a repo, draft PLAN.md, then STOP for human plan review.
        plan   [REPO]   ONE plan-drafting turn on the PLAN tier, then STOP for human review (never auto-runs).
                        --auto: unattended (AUTOPLAN tier, no review-stop) — for the nightly/interval scheduler.
        doctor [REPO]   Preflight: conf parses, tracker has open tasks, keys live, protocol current.
        selftest         Verify detection + loop logic against fixtures (NO agent calls). Exits 0/1.
        stats   [REPO]  Parse this repo's loop.log and print the baseline metrics, then exit.
        watch   [REPO]  Pretty-print the live session JSONL the agent writes (run in a 2nd terminal).
        models          Model config UX: list | add <provider/id> | remove <provider/id> |
                        thinking <level>. Flags: --tier models|plan|build|light (default:
                        models), --pos first|last|N, --repo (edit .ratchet.conf instead of
                        the global conf), --force (skip pi-registry validation). Ids are
                        validated against 'pi --list-models' (24h cache; doctor warns too).

      Options:
        -d, --dir DIR          Repo directory (default: $PWD). A bare positional works too.
        -p, --prompt TEXT      Prompt sent each turn (default: built-in generic do-one-step prompt).
        -m, --models LIST      Comma-separated fallback chain, provider/id form.
            --agent-cmd CMD    Headless agent command (default: pi; e.g. claude, /path/to/agent).
        -s, --session NAME     Session id suffix (default: ratchet-<project-slug>).
            --thinking LEVEL   Reasoning level each turn: off|minimal|low|medium|high|xhigh.
            --turn-timeout N   Max seconds for one turn (default: 1800).
            --cooldown N       Seconds to skip a benched model (default: 14400).
            --step-token T     Per-step completion token (default: STEP_COMPLETE).
            --done-token T     All-done token (default: ALL_DONE).

        Commit-per-turn (the loop owns the commit, gated on green):
            --commit / --no-commit   Commit after each green turn (default: on).
            --verify-cmd CMD         Green gate re-run before each commit. A RED tree never commits.
                                     Empty (default) = LOUD warning, gate skipped, never silent.
            --no-verify-gate         Skip the pre-commit re-verify (commit on the agent's word).
            --push                   Push ONCE after ALL_DONE only (default: off; human owns push).
            --pr                     After ALL_DONE: push branch + open PR/MR (gh/glab); human merges.
            --approve                Open a local diff-review UI before push/PR (opt-in, v1/unproven).

        Token economy (quota):
            --resume / --no-resume   Ephemeral turns are the DEFAULT (tracker = memory, ~90% cheaper).
            --cache-retention R      Prompt-cache TTL: long|short|none (default: long).
            --no-sanitize            Don't strip prior thinking blocks (disable only to debug replay).

        Feedback / observability:
            --tail N / --heartbeat N / --stream / --quiet

        Model selection:
            --cheap                  Force ALL tiers to the LIGHT chain (LIGHT_MODELS, else MODELS).
            --auto                   (plan) Unattended plan turn: AUTOPLAN_MODELS chain, no review-stop.
                                     For schedulers. A caught-up repo gets a KTLO plan instead of silence.
                                     The one-word overnight-on-the-cheap-model switch. Use -m for
                                     an explicit chain override.

        -v, --verbose          Verbose logging.   -h, --help  Show this help.

      Where to look while it runs:
        loop log   $RATCHET_HOME/logs/<slug>/loop.log        (tail -f to watch)
        agent out  $RATCHET_HOME/logs/<slug>/last_turn.out    (what the agent said/did)
    USAGE

    module_function

    def ratchet_home
      ENV["RATCHET_HOME"] || File.join(ENV["HOME"], ".ratchet")
    end

    # bash emit tees to $LOOP_LOG once main() wires the logs up (common.sh:108);
    # QUIET=1 makes it log-only (no stdout) once the log is wired.
    def emit(msg)
      line = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}"
      if !@loop_log
        puts line
      elsif @quiet
        File.write(@loop_log, "#{line}\n", mode: "a")
      else
        puts line
        File.write(@loop_log, "#{line}\n", mode: "a")
      end
    end

    # bash `die` — emit + exit 1.
    def die(msg)
      emit("FATAL: #{msg}")
      exit 1
    end

    # POSIX cksum (MSB-first CRC-32, poly 0x04C11DB7, init 0, length appended
    # little-endian, complemented) — must match bash `cksum` for log slugs.
    def posix_cksum(data)
      crc = 0
      upd = lambda do |b|
        crc ^= b << 24
        8.times { crc = (crc & 0x80000000).zero? ? (crc << 1) & 0xFFFFFFFF : ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF }
      end
      data.each_byte { |b| upd.call(b) }
      len = data.bytesize
      while len.positive?
        upd.call(len & 0xFF)
        len >>= 8
      end
      (~crc) & 0xFFFFFFFF
    end

    # project_slug: cleaned basename + first 6 cksum digits of the abs path.
    def project_slug(dir)
      base = File.basename(dir).gsub(/[^A-Za-z0-9-]/, "-").gsub(/-{2,}/, "-").gsub(/\A-+|-+\z/, "")
      "#{base}-#{posix_cksum(dir).to_s[0, 6]}"
    end

    # bash `command -v X` semantics (aliases/functions aside, PATH lookup is
    # what doctor needs). Shelled out for exactness.
    def on_path?(cmd)
      system("sh", "-c", "command -v -- \"\$1\" >/dev/null 2>&1", "sh", cmd)
    end

    def usage(conf_dir = File.join(ratchet_home, "conf"))
      print HELP_BODY
      puts
      puts "Config:  repo .ratchet.conf (PARSED, never sourced)  >  #{conf_dir} (sourced)  >  defaults."
    end

    COMMANDS = %w[init new plan doctor run once selftest stats watch status models fanout fanout-clean].freeze

    # Flags that swallow the NEXT argv item as their value (bash pre_scan's
    # shift-2 list). Only the tolerant pre-scan needs this; the authoritative
    # parse is OptionParser and knows its own arity.
    PRESCAN_VALUE_FLAGS = %w[-p --prompt -s --session -m --models --thinking --turn-timeout --cooldown
                             --both-wait --step-token --done-token --verify-cmd --agent-cmd
                             --cache-retention --tail --heartbeat].freeze

    # Tolerant pre-scan (bin/ratchet:44): extract ONLY the subcommand + repo
    # dir (+ the `new` idea) so the repo conf can load before the
    # authoritative parse. Skips everything else; never errors.
    def pre_scan(argv)
      command = nil
      dir = nil
      idea = nil
      i = 0
      while i < argv.length
        a = argv[i]
        case a
        when "-d", "--dir" then dir = argv[i + 1]; i += 2
        when /\A--dir=/ then dir = a.sub(/\A--dir=/, ""); i += 1
        when *PRESCAN_VALUE_FLAGS then i += 2
        when *COMMANDS then command ||= a; i += 1
        when /\A-/ then i += 1
        else
          if command == "new" && idea.nil? then idea = a
          elsif dir.nil? then dir = a
          end
          i += 1
        end
      end
      command ||= "run"
      [command, dir, idea]
    end

    # Authoritative parse (bin/ratchet:75 parse_args): OptionParser over the
    # full flag surface; unknown option -> bash `die` message shape (exit 1).
    # Returns the conf-key => value overrides hash (values are strings, the
    # same "1"/"0"/raw-text encoding .ratchet.conf uses).
    def parse!(argv, command, prescan_dir, _idea)
      o = {}
      op = OptionParser.new do |p|
        p.on("-d DIR", "--dir=DIR") { |v| o[:dir] = v }
        p.on("-p TEXT", "--prompt=TEXT") { |v| o["PROMPT_OVERRIDE"] = v }
        p.on("-s NAME", "--session=NAME") { |v| o["SESSION_NAME"] = v }
        p.on("-m LIST", "--models=LIST") { |v| o["MODELS"] = v }
        p.on("--agent-cmd=CMD") { |v| o["AGENT_CMD"] = v }
        p.on("--thinking=LEVEL") { |v| o["THINKING"] = v }
        p.on("--turn-timeout=N") { |v| o["TURN_TIMEOUT"] = v }
        p.on("--cooldown=N") { |v| o["COOLDOWN"] = v }
        p.on("--both-wait=N") { |v| o["BOTH_WAIT"] = v }
        p.on("--step-token=T") { |v| o["STEP_TOKEN"] = v }
        p.on("--done-token=T") { |v| o["DONE_TOKEN"] = v }
        p.on("--commit") { o["COMMIT_EACH_TURN"] = "1" }
        p.on("--no-commit") { o["COMMIT_EACH_TURN"] = "0" }
        p.on("--verify-cmd=CMD") { |v| o["VERIFY_CMD"] = v }
        p.on("--no-verify-gate") { o["COMMIT_VERIFY_GATE"] = "0" }
        p.on("--push") { o["PUSH_ON_DONE"] = "1" }
        p.on("--pr") { o["OPEN_PR"] = "1"; o["PUSH_ON_DONE"] = "1" }
        p.on("--approve") { o["APPROVE_UI"] = "1" }
        p.on("--resume") { o["RESUME_SESSION"] = "1" }
        p.on("--no-resume") { o["RESUME_SESSION"] = "0" }
        p.on("--cache-retention=R") { |v| o["CACHE_RETENTION"] = v }
        p.on("--no-sanitize") { o["SANITIZE_THINKING"] = "0" }
        p.on("--tail=N") { |v| o["TAIL_LINES"] = v }
        p.on("--heartbeat=N") { |v| o["HEARTBEAT"] = v }
        p.on("--stream") { o["STREAM_AGENT"] = "1" }
        p.on("--cheap") { o["CHEAP_MODE"] = "1" }
        p.on("--auto") { o["AUTO_PLAN"] = "1" }
        p.on("--quiet") { o["QUIET"] = "1"; o["STREAM_AGENT"] = "0" }
        p.on("--selftest") { o[:cmd] = "selftest" }
        p.on("--stats") { o[:cmd] = "stats" }
        p.on("--watch") { o[:cmd] ||= "watch" }
        p.on("-v", "--verbose") { o["VERBOSE"] = "1" }
        p.on("-h", "--help") { usage; exit 0 }
      end
      begin
        # parse! mutates: options are stripped, POSITIONALS are what's left.
        op.parse!(argv)
      rescue OptionParser::ParseError => e
        die "unknown option: #{e.args.first} (see --help)"
      end
      argv.each do |a|
        next if a == command || a == prescan_dir # subcommand / pre_scanned dir (bin/ratchet:99,110)
        if command == "new" && o["PROMPT_OVERRIDE"].nil?
          o["PROMPT_OVERRIDE"] = a # for `new`, the idea rides in the prompt slot
        else
          die "unexpected argument: #{a}"
        end
      end
      o
    end

    def run(argv)
      command, dir, idea = pre_scan(argv)
      @overrides = parse!(argv, command, dir, idea)
      dir = @overrides.delete(:dir) || dir
      command = @overrides.delete(:cmd) || command

      case command
      when "doctor"
        warn_conf_issues(dir || ".") # main() parses the repo conf before dispatch
        cmd_doctor(File.expand_path(dir || Dir.pwd))
      when "status"
        warn_conf_issues(dir || ".")
        cmd_status(dir)
      when "once"
        warn_conf_issues(dir || ".")
        cmd_once(dir)
      when "run"
        warn_conf_issues(dir || ".")
        Robur::Loop.run(dir || ".")
      when *COMMANDS
        die "#{command}: not ported yet (M6)"
      else die("unknown command: #{command.inspect}")
      end
    end

    # main() parity (ratchet/bin/ratchet:307): any command with a repo conf
    # that fails to parse surfaces a stderr warning — tolerate at run time,
    # doctor is the strict gate. Uses the RAW dir arg like bash REPO_DIR.
    def warn_conf_issues(dir)
      conf = File.join(dir, ".ratchet.conf")
      return unless File.directory?(dir) && File.file?(conf)
      _, errors = Robur::Config.parse_repo(File.read(conf))
      return if errors.empty?
      warn "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] WARNING: #{dir}/.ratchet.conf has issues (run 'ratchet doctor'):"
      warn "\n" + errors.join("\n")
    end

    # ponytail: only the no-.ratchet.conf doctor path is ported (the only one
    # the M1 suite exercises); conf-parsing checks arrive with the Config port.
    def cmd_doctor(dir)
      problems = doctor_report(dir, out: $stdout)
      exit problems
    end

    # The doctor body, printable to any IO so `once` can run it quiet first.
    def doctor_report(dir, out: $stdout)
      problems = 0
      pr_ok = ->(m) { out.puts "  ok   #{m}" }
      pr_fail = lambda do |m|
        out.puts "  FAIL #{m}"
        problems += 1
      end

      # wire up logs like main() does before dispatch, so last-log exists
      slug = project_slug(dir)
      log_dir = File.join(ratchet_home, "logs", slug)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(File.join(dir, ".ratchet"))
      File.write(File.join(dir, ".ratchet", "last-log"), "#{log_dir}\n")

      out.puts "doctor: #{dir}"

      # conf parsed up front (PARSED, never sourced — see Robur::Config trust
      # boundary); the agent check below reads the conf AGENT_CMD. Reporting
      # keeps the baseline line order: agent check, then conf-parse result.
      conf_path = File.join(dir, ".ratchet.conf")
      conf_values = {}
      conf_errors = []
      if File.file?(conf_path)
        conf_values, conf_errors = Robur::Config.parse_repo(File.read(conf_path))
      end

      pr_ok.call("git repo") if File.directory?(File.join(dir, ".git"))
      # conf AGENT_CMD overrides the built-in default (commands.sh:766 checks
      # the effective $AGENT_CMD, which parse_repo_conf has already overridden).
      agent = conf_values["AGENT_CMD"] || "pi"
      if on_path?(agent)
        pr_ok.call("agent command '#{agent}' on PATH")
      else
        pr_fail.call("agent command '#{agent}' not found (set AGENT_CMD / install it)")
      end

      if File.file?(conf_path)
        if conf_errors.empty?
          pr_ok.call(".ratchet.conf parses (allowlisted keys)")
        else
          pr_fail.call(".ratchet.conf has errors:")
          # baseline: printf '%b\n' "$RATCHET_CONF_ERRORS" | sed 's/^/         /'
          # where the errors string starts with \n — hence the blank line.
          out.puts ("\n" + conf_errors.join("\n")).gsub(/^/, "         ")
        end
        case conf_values["RATCHET_PROTOCOL"] || "1"
        when "1" then pr_ok.call("RATCHET_PROTOCOL=1 supported")
        else pr_fail.call("RATCHET_PROTOCOL=#{conf_values["RATCHET_PROTOCOL"]} unsupported (want 1)")
        end
      else
        pr_fail.call("no .ratchet.conf (run: #{PROG} init #{dir})")
      end

      agents = File.join(dir, "AGENTS.md")
      if File.file?(agents) && File.read(agents) =~ /ratchet-protocol:.*:begin/
        pr_fail.call("AGENTS.md carries a legacy loop-in-file protocol block; run `#{PROG} init #{dir}` to migrate (loop protocol now travels in the harness prompt)")
      else
        pr_ok.call("protocol delivery: harness-prompt (loop briefs its own turns)")
      end

      tr = %w[PLAN.md TODO.md TASKS.md].find { |f| File.file?(File.join(dir, f)) }
      if tr
        plan = Plan.new(File.join(dir, tr))
        content = File.read(File.join(dir, tr))
        # tracker_has_open is a plain grep (no heading skip); tracker_count_done
        # counts [x] only, lowercase.
        if content =~ /^[[:space:]]*-?[[:space:]]*\[ \]/
          pr_ok.call("tracker '#{tr}' has an open task")
          # tracker_next_id_and_text: first IN PROGRESS task, else first open
          t = plan.next_task(:in_progress) || plan.next_task(:open)
          if t.nil? || t.id == "?"
            pr_fail.call("task id unresolved on first open task; parser degraded to '?' (see tracker grammar)")
          end
        elsif content.scan(/^[[:space:]]*-?[[:space:]]*\[x\]/).any?
          pr_ok.call("tracker '#{tr}' fully done (all [x]) — loop final-commits + stops")
        else
          pr_fail.call("tracker '#{tr}' has NO tasks (empty/unparsed) — add work")
        end
      else
        pr_fail.call("no tracker found (PLAN.md/TODO.md/TASKS.md) — run: #{PROG} init #{dir}")
      end

      verify_cmd = conf_values["VERIFY_CMD"] || ENV["VERIFY_CMD"]
      if verify_cmd.to_s.empty?
        pr_fail.call("VERIFY_CMD is EMPTY — set it in .ratchet.conf (no-gate is loud by design)")
      else
        pr_ok.call("VERIFY_CMD is set: '#{verify_cmd}'")
        # dry-run: resolve first token (commands.sh:822)
        first = verify_cmd.split[0]
        builtins = %w[if then else elif fi for while do done case esac function return continue break :]
        if !builtins.include?(first) && !on_path?(first) && !File.readable?(File.join(dir, first))
          pr_fail.call("VERIFY_CMD references unresolved executable: '#{first}' (not found via command -v or as file)")
        end
      end

      pr_ok.call("tokens: defined in conf (prompt delivery)")

      if on_path?("gitleaks")
        pr_ok.call("gitleaks available (rich secret scan)")
      else
        pr_ok.call("gitleaks missing — builtin pattern scan will run (install gitleaks for more)")
      end

      pr_ok.call("pi registry cache missing/stale — model validation skipped (refresh: #{PROG} models list)")
      pr_ok.call("rank source: none (unranked no-join: 0)")

      out.puts "---"
      out.puts "tier routing:"
      out.puts "  PLAN  : → MODELS (flat) (thinking=)"
      out.puts "  AUTOPL: → PLAN (thinking=)"
      out.puts "  BUILD : → MODELS (flat) (thinking=)"
      out.puts "  LIGHT : → MODELS (flat) (thinking=)"
      out.puts "---"
      if problems.zero?
        out.puts "doctor: OK — repo is loop-ready."
      else
        out.puts "doctor: #{problems} problem(s). Fix before running the loop."
      end
      problems
    end

    # bash `status` (commands.sh:cmd_status): one-shot snapshot of a running
    # or finished loop, reading loop.log + tracker + last_turn.out and
    # checking loop.pid for liveness. Note the bash quirk this preserves ON
    # PURPOSE for byte parity: unlike run/once/doctor, TRACKER_FILE here is
    # NEVER defaulted to PLAN.md via detect_tracker_file, so a repo with a
    # PLAN.md but no .ratchet.conf TRACKER_FILE= line shows "?" counts.
    def cmd_status(dir)
      dir = File.expand_path(dir || Dir.pwd)
      log_dir = File.join(ratchet_home, "logs", project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(File.join(dir, ".ratchet"))
      File.write(File.join(dir, ".ratchet", "last-log"), "#{log_dir}\n")
      log = File.join(log_dir, "loop.log")
      unless File.file?(log)
        puts "status: no loop.log found at #{log} (nothing run here yet?)"
        exit 1
      end
      print status_report(dir, log_dir, log)
      0
    end

    def status_report(dir, log_dir, log)
      tracker = File.join(dir, Config.load(dir)[:values]["TRACKER_FILE"].to_s)
      turn_out = File.join(log_dir, "last_turn.out")
      log_text = File.read(log)

      node, merge_pr, merge_since = status_node(log_text)
      review_cycle = (cur = State.read_milestone_cur(dir)) ? cur[2] : 0
      turn_num, tier, model, thinking, task = status_turn_line(log_text)
      elapsed_took = status_elapsed(log_text, turn_num)
      done_n, open_n, total_n = status_task_counts(tracker)
      loop_alive_dot, loop_status = status_liveness(File.join(log_dir, "loop.pid"))
      pct = total_n != "?" && total_n.positive? ? (done_n * 100 / total_n) : 0

      plan = File.file?(tracker) ? Plan.new(tracker) : nil
      cur_ms = plan&.current_milestone
      mname = cur_ms&.fetch(:name)

      avg_s = Observability.avg_turn_secs(log)
      remaining_n = open_n == "?" ? 0 : open_n
      eta_str = Render.eta(remaining_n, avg_s)

      out = +"#{Render.c_bold(File.basename(dir))} #{loop_alive_dot}\n"
      out << "Step #{done_n}/#{total_n}  [#{Render.c_green(Render.bar(pct, 12))} #{Render.c_blue("#{pct}%")}]\n"
      plan&.milestones&.each do |ms|
        ms_pct = ms[:total].positive? ? ms[:done] * 100 / ms[:total] : 0
        line = format("%-34s [%s]  %d/%d", ms[:name], Render.bar(ms_pct, 6), ms[:done], ms[:total])
        out << (ms[:name] == mname ? "#{Render.c_blue('▶')} #{Render.c_bold(line)}\n" : "  #{Render.c_dim(line)}\n")
      end
      out << "\nCurrent: #{Render.c_bold(task)}\n" if task != "\u2014"
      out << "Tier/Model: #{Render.c_purple(tier)} / #{Render.c_purple(model)} (thinking=#{thinking})\n"
      out << (review_cycle.positive? ? "Node: #{node} (review cycle #{review_cycle})\n" : "Node: #{node}\n")
      out << "Waiting on PR #{merge_pr} since #{merge_since}\n" if node == "merge-wait" && !merge_pr.empty?
      out << "Turn #{turn_num}: #{elapsed_took}\n" if turn_num != "\u2014"
      out << "ETA: #{eta_str}\n"
      doing_now = status_doing_now(turn_out)
      out << "\nDoing: #{doing_now}\n" if doing_now && !doing_now.empty?
      out << (loop_status.start_with?("running") ? "\nLoop: #{Render.c_green(loop_status)}\n" : "\nLoop: #{Render.c_dim(loop_status)}\n")
      out << "Log: #{log}\n"
      out
    end

    # Newest state line -> [node, merge_pr, merge_since] (commands.sh:286).
    def status_node(log_text)
      node_line = log_text.lines.select { |l| l =~ /milestone-complete|review-pass|review-fail|review-skip|merge-wait/ }.last
      return ["build", "", ""] unless node_line

      node_ts = node_line[/\A\[([^\]]+)\]/, 1].to_s
      case node_line
      when /milestone-complete/ then ["review", "", ""]
      when /review-pass|review-fail|review-skip/ then ["build", "", ""]
      when /merge-wait/
        if node_line.include?("state=OPEN")
          ["merge-wait", node_line[/pr=([^|\s]+)/, 1].to_s, node_ts]
        else
          ["build", "", ""]
        end
      else ["build", "", ""]
      end
    end

    # Last turn line -> [turn_num, tier, model, thinking, task]
    # (commands.sh:306), including the old-format fallback whose model regex
    # stops at the first '-' (`[^-[:space:]]+`) — a bash quirk preserved for
    # byte parity, not fixed.
    def status_turn_line(log_text)
      lines = log_text.lines
      turn_line = lines.select { |l| l =~ /\A\[[^\]]+\] turn \d+ \| tier=/ }.last
      if turn_line
        [turn_line[/turn (\d+) /, 1], turn_line[/tier=([^|\s]+)/, 1], turn_line[/model=([^|\s]+)/, 1],
         turn_line[/thinking=([^|\s]+)/, 1], turn_line[/task=(.*)\z/, 1].to_s.strip]
      elsif (turn_line = lines.select { |l| l =~ /\A\[[^\]]+\] --- turn \d+ \| model=/ }.last)
        [turn_line[/turn (\d+) /, 1], "\u2014", turn_line[/model=([^-\s]+)/, 1], "\u2014", "\u2014"]
      else
        ["\u2014"] * 5
      end
    end

    # Same-turn end line -> "took Ns" / "finished" / "running" (commands.sh:333).
    def status_elapsed(log_text, turn_num)
      end_line = log_text.lines.select { |l| l =~ /\A\[[^\]]+\] turn \d+ end \| class=/ }.last
      return "running" unless end_line && end_line[/turn (\d+) end/, 1] == turn_num

      took = end_line[/took=(\d+)s/, 1]
      took ? "took #{took}s" : "finished"
    end

    # [done, open, total] as plain (non-heading-aware) grep counts
    # (commands.sh:346) — "?" triples when there is no tracker to count.
    def status_task_counts(tracker)
      return %w[? ? ?] unless File.file?(tracker)

      lines = File.readlines(tracker)
      done_n = lines.count { |l| l =~ /\A[[:space:]]*-?[[:space:]]*\[x\]/ }
      open_n = lines.count { |l| l =~ /\A[[:space:]]*-?[[:space:]]*\[( |IN PROGRESS)\]/ }
      [done_n, open_n, done_n + open_n]
    end

    # loop.pid -> [dot, status text] (commands.sh:358).
    def status_liveness(pid_file)
      return ["\u25CB", "not running"] unless File.file?(pid_file)

      pid = File.read(pid_file).strip
      if !pid.empty? && process_alive?(pid)
        [Render.ansi_ok? ? "\u25CF" : "*", "running (pid #{pid})"]
      else
        ["\u25CB", "not running (stale pid #{pid})"]
      end
    end

    def process_alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue StandardError
      false
    end

    # last_turn.out -> the last non-blank summary line (commands.sh:441),
    # handling both plain-text agent output and the pi JSON stream (joining
    # text_delta fragments). ponytail: only \n, \t, \\ and \" are
    # unescaped from printf '%b' — full octal/hex escape support is not worth
    # it for a status preview line; widen if a real transcript needs it.
    def status_doing_now(turn_out)
      return nil unless File.file?(turn_out) && !File.zero?(turn_out)

      content = File.read(turn_out)
      if content.byteslice(0, 32).to_s.start_with?('{"type":"session"')
        joined = content.each_line.grep(/"type":"text_delta"/)
                         .map { |l| l.sub(/.*"delta":"/, "").sub(/","partial.*/, "") }
                         .join.gsub('\\"', '"')
                         .gsub('\\n', "\n").gsub('\\t', "\t").gsub('\\\\', '\\')
        Render.summary(joined, 1)
      else
        Render.summary(content, 1)
      end
    end

    # term_only: stdout only, never the loop log (common.sh:124); a no-op
    # under QUIET=1.
    def term_only(msg)
      return if @quiet

      puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}"
    end

    # flow: raw passthrough (no timestamp prefix), same QUIET gating as emit —
    # for multi-line agent excerpts (common.sh:115 flow).
    def flow(text)
      if !@loop_log
        print text
      elsif @quiet
        File.write(@loop_log, text, mode: "a")
      else
        print text
        File.write(@loop_log, text, mode: "a")
      end
    end

    # commit_turn (commit-gate.sh:60): delegates to CommitGate, which owns the
    # stage/exclude/scan/verify/commit ordering; CLI supplies the loop.log
    # emit sink so the gate's prose lands in the same rendered log.
    def commit_turn(turn, model, conf, plan, dir)
      Robur::CommitGate.new(dir, plan: plan, config: conf, emit: method(:emit), loop_log: @loop_log)
                        .run(turn: turn, model: model)
    end

    # _turn_usage FILE -> "in\tout\tcost" (observability.sh:215): per-message
    # usage deltas, deduped by id/message.id/responseId, last wins.
    def turn_usage(path)
      last = {}
      File.foreach(path) do |line|
        ev = begin
          JSON.parse(line)
        rescue JSON::ParserError, ArgumentError
          next
        end
        msg = ev["message"] || {}
        u = ev["usage"] || msg["usage"]
        next if u.nil?

        key = ev["id"] || msg["id"] || msg["responseId"] || ev["responseId"] || line
        cost = (u["cost"] || {})["total"] || 0.0
        last[key] = [u["input"] || 0, u["output"] || 0, cost]
      end
      totals = last.values.inject([0, 0, 0.0]) { |a, v| [a[0] + v[0], a[1] + v[1], a[2] + v[2]] }
      format("%d\t%d\t%.6f", *totals)
    rescue Errno::ENOENT
      "0\t0\t0"
    end

    # metrics_append (observability.sh:239): 12 frozen columns.
    def metrics_append(repo_dir, event, turn, tier, model, klass, took, task, tin, tout, cost)
      f = ENV["RATCHET_METRICS"] || File.join(ratchet_home, "metrics.tsv")
      FileUtils.mkdir_p(File.dirname(f))
      row = [Time.now.strftime("%F %T"), File.basename(repo_dir), event, turn, tier, model,
             klass, took, task, tin, tout, cost].join("\t")
      File.write(f, "#{row}\n", mode: "a")
    rescue StandardError
      nil
    end

    # avg_turn_secs (observability.sh:118): int mean of took=Ns lines in loop.log.
    def avg_turn_secs(log)
      return 0 unless File.file?(log)

      vals = File.read(log).scan(/took=(\d+)s/).map { |m| m[0].to_i }
      vals.empty? ? 0 : vals.sum / vals.size
    end

    def fmt_dur(secs)
      return "#{secs}s" if secs < 60
      return "#{secs / 60}m" if secs < 3600

      "#{secs / 3600}h#{(secs % 3600) / 60}m"
    end

    def render_bar(pct, w = 12)
      pct = 0 if pct.negative?
      pct = 100 if pct > 100
      fill = pct * w / 100
      (1..w).map { |i| i <= fill ? "▓" : "░" }.join
    end

    # bash `once` up to the preflight gate (ratchet/bin/ratchet once path):
    # quiet doctor first, loud only on failure, abort before any turn. Then
    # ONE turn of the loop (banner, tier routing, watchdog run, classify,
    # metrics, per-outcome dispatch) — the M4 slice of bin/ratchet's main loop.
    def cmd_once(dir)
      dir = File.expand_path(dir || Dir.pwd)
      log_dir = File.join(ratchet_home, "logs", project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(File.join(dir, ".ratchet"))
      File.write(File.join(dir, ".ratchet", "last-log"), "#{log_dir}\n")
      @quiet = Robur::Config.load(dir, @overrides || {}).values["QUIET"] == "1" # main() parses conf before preflight
      @loop_log = File.join(log_dir, "loop.log") # bash main() wires LOOP_LOG before preflight
      emit "preflight (doctor) ..."
      require "stringio"
      buf = StringIO.new
      problems = doctor_report(dir, out: buf)
      if problems.positive?
        emit "preflight FAILED — run '#{PROG} doctor #{dir}' for details. Aborting before any turn."
        print buf.string
        exit 1
      end
      run_once_loop(dir)
    end

    module_function

    # One turn of bin/ratchet's main loop in --once mode (bin/ratchet:520-866).
    def run_once_loop(dir)
      conf = Robur::Config.load(dir, @overrides || {}).values
      plan = Plan.new(File.join(dir, conf["TRACKER_FILE"] || "PLAN.md"))
      models = Tier.chain_for("build", conf).to_s.split(",").reject(&:empty?)
      die "no models configured (-m chain, MODELS in .ratchet.conf, or global conf)." if models.empty?
      chain = ModelChain.new(models, conf, clock: Sys::Clock.new)
      log_dir = File.dirname(@loop_log)
      turn_out = File.join(log_dir, "last_turn.out")
      run_start = mono
      run_toks = { in: 0, out: 0, cost: 0.0 }

      thinking_banner = conf["THINKING"].to_s.empty? ? "inherit" : conf["THINKING"]
      emit "=" * 60
      emit "ratchet START"
      emit "  repo      : #{dir}"
      emit "  session   : ratchet-#{project_slug(dir)} (resume=no)"
      emit "  tracker   : #{conf["TRACKER_FILE"] || "PLAN.md"}"
      emit "  models    : #{models.join(" ")}  (preference order, fallback chain)"
      emit "  turn cap  : #{conf["TURN_TIMEOUT"]}s   cooldown: #{conf["COOLDOWN"]}s   both-wait: #{conf["BOTH_WAIT"]}s"
      emit "  tokens    : step='#{conf["STEP_TOKEN"]}'  done='#{conf["DONE_TOKEN"]}'"
      emit "  agent     : #{conf["AGENT_CMD"]}"
      emit "  thinking  : #{thinking_banner}"
      emit "  verify    : #{conf["VERIFY_CMD"].to_s.empty? ? "<EMPTY — loud warning, no gate>" : conf["VERIFY_CMD"]}"
      emit "  commit    : per-turn=#{conf["COMMIT_EACH_TURN"] == "1" ? "yes" : "no"}  push-on-done=#{conf["PUSH_ON_DONE"] == "1" ? "yes" : "no"}  pr=#{conf["OPEN_PR"] == "1" ? "yes" : "no"}"
      emit "  loop log  : #{@loop_log}"
      emit "  stop      : Ctrl-C"
      emit "=" * 60

      stop_reason = ""
      turn = 1
      last_model = "none"

      # All-done fast path (bin/ratchet:533): no open/in-progress but has [x].
      if !plan.open? && !plan.in_progress? && plan.count(:done).positive?
        emit "all #{conf["TRACKER_FILE"] || "PLAN.md"} tasks complete (#{plan.count(:done)} done) — no open work remains."
        if commit_turn("final", last_model, conf, plan, dir).block_reason.nil?
          emit "agent signaled #{conf["DONE_TOKEN"]} — all work complete."
        end
        stop_reason = "done"
      else
        stop_reason, last_model = run_single_turn(dir, conf, plan, chain, log_dir, turn_out,
                                                  run_toks, run_start, turn)
      end

      emit "ratchet END after #{turn} turn(s)."
      File.write(File.join(dir, ".ratchet", "stop_reason"), "#{stop_reason}\n")
      state = File.file?(File.join(dir, ".ratchet", "last_task.state")) ? File.read(File.join(dir, ".ratchet", "last_task.state")) : ""
      taskid = state[/\A[^\t]*/].to_s
      metrics_append(dir, "run", "-", "-", last_model, stop_reason, elapsed_int(run_start), taskid,
                     run_toks[:in], run_toks[:out], format("%.6f", run_toks[:cost]))
      0 # exit code, not File.write's byte count (bash: metrics_append's own exit status, always 0)
    end

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def elapsed_int(from) = (mono - from).to_i

    # Runs one turn and dispatches its outcome; returns [stop_reason, model].
    def run_single_turn(dir, conf, plan, chain, log_dir, turn_out, run_toks, run_start, turn)
      task = plan.next_task(:in_progress) || plan.next_task(:open)
      tag = task&.tags&.first
      tier = Tier.from_tag(tag)
      thinking = Tier.thinking_for(tier, conf)
      model = chain.models[chain.pick || 0]
      next_task_str = task ? "#{task.id} (#{task.tags.join(", ")}) #{task.text}" : ""

      done_n = plan.count(:done)
      open_n = plan.count(:open) + plan.count(:in_progress)
      emit "tasks: #{done_n} done / #{done_n + open_n} total | next: #{next_task_str.slice(0, 60)}"

      minfo = plan.current_milestone
      if minfo
        pct = (done_n + open_n).positive? ? done_n * 100 / (done_n + open_n) : 0
        term_only "Step #{done_n}/#{done_n + open_n}  [#{render_bar(pct)} #{pct}%]   #{minfo[:name]}  (#{minfo[:done]}/#{minfo[:total]})"
      else
        term_only "Step #{done_n}/#{done_n + open_n}  [#{render_bar(done_n * 100 / (done_n + open_n))} #{done_n * 100 / (done_n + open_n)}%]"
      end
      taskid = task ? task.id : "?"
      tasktext = task ? task.text : "—"
      term_only "  ▶ #{taskid}  #{tasktext}   #{tier} · #{model}"

      emit "--- turn #{turn} | model=#{model} ---"
      emit "turn #{turn} | tier=#{tier} | model=#{model} | thinking=#{thinking} | task=#{next_task_str}"

      ENV["RATCHET_LOOP"] = "1"
      turn_start = mono
      cmd = [conf["AGENT_CMD"], "--model", model]
      cmd += ["--thinking", thinking] unless thinking.to_s.empty?
      cmd += ["--no-session", "-p", "turn"]
      result = Turn.run(cmd: cmd, turn_file: turn_out, chdir: dir,
                        turn_timeout: conf["TURN_TIMEOUT"].to_i,
                        stall_timeout: conf["STALL_TIMEOUT"].to_i,
                        poll_interval: (ENV["POLL_INTERVAL"] || conf["POLL_INTERVAL"] || 3).to_i)
      status = result.kill_reason ? 128 + (result.status.termsig || 0) : result.status.exitstatus
      deadline = !result.kill_reason.nil?
      klass = Classifier.classify(turn_out, step_token: conf["STEP_TOKEN"], done_token: conf["DONE_TOKEN"],
                                           deadline: deadline, json: false, human_token: conf["HUMAN_TOKEN"])
      took = elapsed_int(turn_start)
      emit "turn #{turn} end | class=#{klass} | took=#{took}s | exitcode=#{status} | task=#{next_task_str.slice(0, 20)}"

      tin, tout, cost = turn_usage(turn_out).split("\t")
      metrics_append(dir, "turn", turn, tier, model, klass, took, taskid, tin, tout, cost)
      run_toks[:in] += tin.to_i
      run_toks[:out] += tout.to_i
      run_toks[:cost] += cost.to_f

      FileUtils.mkdir_p(File.join(dir, ".ratchet"))
      File.write(File.join(dir, ".ratchet", "last_task.state"), "#{taskid}\t#{klass}\n")

      avg = avg_turn_secs(@loop_log)
      eta = avg.zero? ? "ETA unknown" : "~#{open_n} turns / ~#{fmt_dur(open_n * avg)} left"
      term_only "  ⏱ turn #{turn} · #{fmt_dur(took)}   avg #{fmt_dur(avg)}   #{eta}"

      # show_excerpt (observability.sh:41)
      if !ENV.fetch("SUMMARY_LINES", "4").to_i.zero? && File.exist?(turn_out) && !File.zero?(turn_out)
        emit "--- summary ---"
        lines = File.read(turn_out).lines.reject { |l| l =~ /^[[:space:]]*$/ }
        lines.last(ENV.fetch("SUMMARY_LINES", "4").to_i).each { |l| flow l }
        emit "---"
      end

      # ALL_DONE with open tasks is mid-work, not done (bin/ratchet:663).
      klass = :step if klass == :done && (plan.open? || plan.in_progress?)

      commit_result = commit_turn(turn, model, conf, plan, dir)
      case klass
      when :done
        emit "agent signaled #{conf["DONE_TOKEN"]} — all work complete."
        return ["done", model]
      when :human
        emit "agent signaled #{conf["HUMAN_TOKEN"]} — needs a human decision; stopping this repo."
        emit "HUMAN NEEDED: #{plan.human_block_brief(taskid, next_task_str)}"
        return ["human_blocked", model]
      when :step
        unless commit_result.block_reason.nil?
          emit "step turn RED at commit gate — next turn will repair. Sleeping #{conf["SHORT_SLEEP"]}s."
          emit "--once: stopping."
          return ["", model]
        end
        emit "step complete (#{conf["STEP_TOKEN"]}). Sleeping #{conf["SHORT_SLEEP"]}s."
        emit "--once: stopping after one step."
        return ["once", model]
      when :exhausted
        if took < 15
          emit "model #{model} EXHAUSTED (quota/rate-limit) in #{took}s — instant-quota, model was already dry. Benching #{conf["COOLDOWN"]}s; switching."
        else
          emit "model #{model} EXHAUSTED (quota/rate-limit). Benching #{conf["COOLDOWN"]}s; switching."
        end
        chain.bench!(0)
        emit "--once: stopping."
        return ["once", model]
      when :hard
        chain.strike!(0)
        emit "model #{model} HARD ERROR (auth/not-found/bad-request). strike 1/#{conf["MAX_TRANSIENT"]}. See #{turn_out}"
        emit "--once: stopping."
        return ["once", model]
      when :timeout
        dirty = File.directory?(File.join(dir, ".git")) &&
                !Open3.capture3("git", "-C", dir, "status", "--porcelain")[0].empty?
        if dirty && commit_result.committed
          emit "turn killed (#{klass}) but tree was green — salvaged work as a commit; continuing."
          return ["once", model]
        end
        emit "model #{model} TIMEOUT (#{result.kill_reason}, no token/error). strike 1/#{conf["MAX_TRANSIENT"]}; backing off #{conf["SHORT_SLEEP"]}s."
        emit "--once: stopping."
        return ["once", model]
      else # :transient
        chain.strike!(0)
        emit "model #{model} transient failure. strike 1/#{conf["MAX_TRANSIENT"]}; backing off #{conf["SHORT_SLEEP"]}s."
        emit "--once: stopping."
        return ["once", model]
      end
    end
  end
end
