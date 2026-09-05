# frozen_string_literal: true

require "optparse"
require "fileutils"
require "io/console"
require "robur/config"
require "robur/paths"
require "robur/migrate"
require "robur/loop"
require "robur/plan"
require "robur/tier"
require "robur/prompt"
require "robur/model_health"
require "robur/progress_guard"
require "robur/turn"
require "robur/classifier"
require "robur/commit_gate"
require "robur/render"
require "robur/observability"
require "robur/state"
require "robur/commands"
require "robur/models_cmd"

module Robur
  # The command-line surface: argument parsing, command dispatch, and the
  # help/usage text. PROG is the single place the program name appears in
  # user-facing text, so every "run: <prog> ..." hint stays consistent.
  module CLI
    PROG = "robur"

    HELP_BODY = <<~USAGE
      Usage: #{PROG} <command> [REPO_DIR] [OPTIONS]

      #{PROG} — an unattended-but-safe agent loop. Runs a headless coding agent
      (pi, or any -p-style CLI) ONE turn at a time against a repo, surviving provider
      rate limits, gating every commit on a green test suite, and routing shared-state
      actions (push, PR/MR) through a human. A RED tree is never committed.

      Commands:
        run    [REPO]   Run the loop unattended until the agent prints ALL_DONE. (default)
        once   [REPO]   Run exactly one turn, then exit (testing/debugging).
        init   [REPO]   Stamp AGENTS.md protocol + .robur.conf + seed PLAN.md (existing repo).
        new    "<idea>" Scaffold a repo, draft PLAN.md, then STOP for human plan review.
        plan   [REPO]   ONE plan-drafting turn on the PLAN tier, then STOP for human review (never auto-runs).
                        --auto: unattended (AUTOPLAN tier, no review-stop) — for the nightly/interval scheduler.
        doctor [REPO]   Preflight: conf parses, tracker has open tasks, keys live, protocol current.
        selftest         Verify detection + loop logic against fixtures (NO agent calls). Exits 0/1.
        stats   [REPO]  Parse this repo's loop.log and print the baseline metrics, then exit.
        watch   [REPO]  Live board in a 2nd terminal: refreshes step/%/milestones/model/ETA every 2s while `run` works.
        models          Model config UX: list | add <provider/id> | remove <provider/id> |
                        thinking <level>. Flags: --tier models|plan|build|light (default:
                        models), --pos first|last|N, --repo (edit .robur.conf instead of
                        the global conf), --force (skip pi-registry validation). Ids are
                        validated against 'pi --list-models' (24h cache; doctor warns too).

      Options:
        -d, --dir DIR          Repo directory (default: $PWD). A bare positional works too.
        -p, --prompt TEXT      Prompt sent each turn (default: built-in generic do-one-step prompt).
        -m, --models LIST      Comma-separated fallback chain, provider/id form.
            --agent-cmd CMD    Headless agent command (default: pi; e.g. claude, /path/to/agent).
        -s, --session NAME     Session id suffix (default: robur-<project-slug>).
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
        loop log   $ROBUR_HOME/logs/<slug>/loop.log        (tail -f to watch)
        agent out  $ROBUR_HOME/logs/<slug>/last_turn.out    (what the agent said/did)
    USAGE

    module_function

    # emit tees to the loop log once a command has wired it up; QUIET=1 makes
    # it log-only (no stdout) from that point on.
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

    # emit + exit 1.
    def die(msg)
      emit("FATAL: #{msg}")
      exit 1
    end

    # POSIX cksum (MSB-first CRC-32, poly 0x04C11DB7, init 0, length appended
    # little-endian, complemented) — log slugs must match what `cksum` gives,
    # so shell tooling and robur agree on a repo's log directory.
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

    # `command -v X` semantics (PATH lookup is what doctor needs). Shelled out
    # so the answer matches what a spawned turn would actually find.
    def on_path?(cmd)
      system("sh", "-c", "command -v -- \"\$1\" >/dev/null 2>&1", "sh", cmd)
    end

    def usage(conf_dir = Paths.global_conf)
      print HELP_BODY
      puts
      puts "Config:  repo #{Paths::REPO_CONF} (PARSED, never sourced)  >  #{conf_dir} (sourced)  >  defaults."
    end

    COMMANDS = %w[init new plan doctor run once selftest stats watch status models fanout
                  fanout-clean migrate-state].freeze

    # Flags that swallow the NEXT argv item as their value. Only the tolerant
    # pre-scan needs this; the authoritative parse is OptionParser and knows
    # its own arity.
    PRESCAN_VALUE_FLAGS = %w[-p --prompt -s --session -m --models --thinking --turn-timeout --cooldown
                             --both-wait --step-token --done-token --verify-cmd --agent-cmd
                             --cache-retention --tail --heartbeat].freeze

    # Tolerant pre-scan: extract ONLY the subcommand + repo dir (+ the `new`
    # idea) so the repo conf can load before the authoritative parse. Skips
    # everything else; never errors.
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

    # Authoritative parse: OptionParser over the full flag surface; an unknown
    # option dies (exit 1). Returns the conf-key => value overrides hash
    # (values are strings, the same "1"/"0"/raw-text encoding the repo conf
    # uses, so flags and conf keys merge without conversion).
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
        p.on("--apply") { o["MIGRATE_APPLY"] = "1" }
        p.on("--quiet") { o["QUIET"] = "1"; o["STREAM_AGENT"] = "0" }
        p.on("--selftest") { o[:cmd] = "selftest" }
        p.on("--stats") { o[:cmd] = "stats" }
        p.on("--watch") { o[:cmd] ||= "watch" }
        p.on("-v", "--verbose") { o["VERBOSE"] = "1" }
        p.on("-h", "--help") { usage; exit 0 }
        # OptionParser defines --version (and -V) for free, printing its own
        # "<prog>: version unknown". We do not have a version flag, and the
        # freebie would silently swallow it — take the name back and route it
        # to the same die path as any other unknown option.
        p.on("--version") { raise OptionParser::InvalidOption, "--version" }
      end
      begin
        # parse! mutates: options are stripped, POSITIONALS are what's left.
        op.parse!(argv)
      rescue OptionParser::ParseError => e
        die "unknown option: #{e.args.first} (see --help)"
      end
      argv.each do |a|
        next if a == command || a == prescan_dir # subcommand / pre-scanned dir
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
      # `models` owns its own arg parse (model ids + --tier/--pos would trip
      # the general OptionParser) — dispatched right after the conf load and
      # BEFORE the authoritative parse.
      return cmd_models(argv, dir) if command == "models"

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
      when "watch"
        warn_conf_issues(dir || ".")
        cmd_watch(dir)
      when "once"
        warn_conf_issues(dir || ".")
        cmd_once(dir)
      when "run"
        warn_conf_issues(dir || ".")
        cmd_run(dir)
      when "init"
        cmd_init(dir)
      when "new"
        cmd_new(@overrides["PROMPT_OVERRIDE"], dir)
      when "plan"
        warn_conf_issues(dir || ".")
        cmd_plan(dir)
      when "fanout"
        warn_conf_issues(dir || ".")
        cmd_fanout(dir)
      when "fanout-clean"
        warn_conf_issues(dir || ".")
        cmd_fanout_clean(dir)
      when "stats"
        warn_conf_issues(dir || ".")
        cmd_stats(dir)
      when "migrate-state"
        cmd_migrate_state(dir)
      when *COMMANDS
        die "#{command}: not ported yet (M6)"
      else die("unknown command: #{command.inspect}")
      end
    end

    # migrate-state [REPO] [--apply] — move live state onto robur's own names,
    # leaving a symlink at every legacy path. Dry-run unless --apply: this
    # walks a real home directory with hundreds of log dirs, so the default
    # has to be the one that cannot lose anything.
    def cmd_migrate_state(dir)
      apply = (@overrides || {})["MIGRATE_APPLY"] == "1"
      repos = dir ? [File.expand_path(dir)] : []
      actions = Migrate.plan(repos: repos)
      puts Migrate.render(actions, apply: apply)
      if apply
        done = Migrate.apply!(actions)
        puts "  applied #{done.size} change(s)"
      end
      0
    end

    def cmd_init(dir)
      dir = File.expand_path(dir || Dir.pwd)
      wire_logs!(dir)
      Commands.init(dir, emit: method(:emit))
      0 # exit code, not Commands.init's own return value
    rescue StandardError => e
      die e.message
    end

    # LOG_DIR/loop.log/last-log wiring happens ONCE, before EVERY command
    # dispatch (not just run/once) — `emit` tees to loop.log and
    # `status`/`stats` read the same log_dir back. `doctor` does its own copy
    # inline (Commands.doctor_report); every other command that emits needs
    # this called first.
    def wire_logs!(dir)
      log_dir = File.join(Paths.logs_dir, project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")
      @loop_log = File.join(log_dir, "loop.log")
      log_dir
    end

    # Strips the FIRST literal "models" token from argv (wherever it falls)
    # and hands the rest to cmd_models, after the global+repo conf load but
    # before the authoritative parse.
    def cmd_models(argv, dir)
      warn_conf_issues(dir || ".")
      repo_dir = File.expand_path(dir || Dir.pwd)
      conf = Robur::Config.load(repo_dir).values
      margs = argv.dup
      idx = margs.index("models")
      margs.delete_at(idx) if idx
      Robur::ModelsCmd.run(margs, config: conf, dir: repo_dir, emit: method(:emit))
      0
    rescue StandardError => e
      die e.message
    end

    def cmd_new(idea, dir)
      dir = File.expand_path(dir || Dir.pwd)
      wire_logs!(dir)
      Commands.new_repo(idea, dir, emit: method(:emit))
      0 # exit code, not Commands.new_repo's own return value
    rescue StandardError => e
      die e.message
    end

    def cmd_plan(dir)
      dir = File.expand_path(dir || Dir.pwd)
      log_dir = File.join(Paths.logs_dir, project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")
      conf = Robur::Config.load(dir, @overrides || {}).values
      @quiet = conf["QUIET"] == "1"
      @loop_log = File.join(log_dir, "loop.log")
      turn_out = File.join(log_dir, "last_turn.out")
      Commands.plan(dir, conf, auto: conf["AUTO_PLAN"] == "1", turn_out: turn_out, emit: method(:emit))
      0 # exit code, not Commands.plan's own return value
    rescue StandardError => e
      die e.message
    end

    # Any command whose repo conf fails to parse surfaces a stderr warning —
    # tolerate at run time, doctor is the strict gate. Uses the RAW dir arg so
    # the message names the path the user typed.
    def warn_conf_issues(dir)
      conf = Paths.repo_conf(dir)
      return unless File.directory?(dir) && File.file?(conf)
      _, errors = Robur::Config.parse_repo(File.read(conf))
      return if errors.empty?
      warn "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] WARNING: #{conf} has issues (run '#{PROG} doctor'):"
      warn "\n" + errors.join("\n")
    end

    # The model chain is validated before the log is read, so the empty-chain
    # message wins over a missing loop.log.
    def cmd_stats(dir)
      dir = File.expand_path(dir || Dir.pwd)
      log_dir = File.join(Paths.logs_dir, project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")
      conf = Config.load(dir, @overrides || {}).values
      @quiet = conf["QUIET"] == "1"
      @loop_log = File.join(log_dir, "loop.log")
      chain = conf["MODELS"].to_s
      flat = chain.split(",").reject(&:empty?)
      die "no models configured (MODELS='#{chain}')" if flat.empty?
      puts Observability.stats(log_dir, cheap_model: flat.first)
      puts "source                : #{Observability.stats_source(log_dir)}"
      0
    rescue StandardError => e
      die e.message
    end

    def cmd_doctor(dir)
      problems = Commands.doctor_report(dir, out: $stdout)
      exit problems
    end

    # One-shot snapshot of a running or finished loop, reading loop.log +
    # tracker + last_turn.out and checking loop.pid for liveness. Unlike
    # run/once/doctor, TRACKER_FILE here is NEVER defaulted to PLAN.md, so a
    # repo with a PLAN.md but no TRACKER_FILE= line in its conf shows "?"
    # counts rather than implying it read a tracker it was never pointed at.
    def cmd_status(dir)
      dir = File.expand_path(dir || Dir.pwd)
      log_dir = File.join(Paths.logs_dir, project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")
      log = File.join(log_dir, "loop.log")
      unless File.file?(log)
        puts "status: no loop.log found at #{log} (nothing run here yet?)"
        exit 1
      end
      print status_report(dir, log_dir, log)
      0
    end

    # Live board: refreshes every 2s until the loop process is gone (one
    # final frame) or Ctrl-C. Redraws IN PLACE — cursor home + erase-below, one
    # buffered write per frame, cursor hidden — a full-screen clear per tick
    # is what made it flicker.
    def cmd_watch(dir)
      dir = File.expand_path(dir || Dir.pwd)
      log_dir = File.join(Paths.logs_dir, project_slug(dir))
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")
      log = File.join(log_dir, "loop.log")
      unless File.file?(log)
        puts "watch: no loop.log found at #{log} (nothing run here yet?)"
        return 1
      end
      ansi = Render.ansi_ok?
      print "\e[?25l" if ansi # hide cursor while redrawing
      loop do
        rows, cols = CLI.term_size
        sr = status_report(dir, log_dir, log)
        frame = +sr
        prompt_file = File.join(log_dir, "last_prompt.txt")
        if File.file?(prompt_file)
          n = File.readlines(prompt_file).size
          frame << "\nAsked: #{Render.c_dim("#{prompt_file} (#{n} lines)")}\n"
        end
        live = turn_text(File.join(log_dir, "last_turn.out"))
        unless live.to_s.empty?
          # Prose lines carry no ANSI; clamp width so a long line cannot wrap
          # and shift every following redraw (overprint palimpsest). Budget
          # the block so the whole frame fits the screen — a taller frame
          # scrolls, and \e[H then homes to a scrolled row: same palimpsest.
          live = live.lines(chomp: true).map { |l| l[0, cols - 1] }.join("\n")
          n = [rows - sr.lines.size - 5, 0].max
          frame << "\n#{Render.c_bold("Live output")}\n#{Render.summary(live, [n, 15].min)}\n" if n.positive?
        end
        _, loop_status = status_liveness(File.join(log_dir, "loop.pid"))
        running = loop_status.start_with?("running")
        frame << "\nloop not running — final state above.\n" unless running
        lines = frame.lines
        lines = lines.first(rows - 1) if lines.size > rows - 1 # whole-line trim keeps ANSI intact
        if ansi
          # \e[K per line: \e[J alone only erases AFTER the final cursor
          # position, so any row that got shorter between frames kept its
          # stale tail ("running7s", "(thinking=)ff)=)").
          print "\e[H#{lines.map { |l| "#{l.chomp}\e[K" }.join("\n")}\e[J"
        else
          print "\n#{lines.join}"
        end
        return 0 unless running
        sleep 2
      end
    rescue Interrupt
      0
    ensure
      print "\e[?25h" if Render.ansi_ok? # cursor back, even on interrupt
    end

    def status_report(dir, log_dir, log)
      tracker = File.join(dir, Config.load(dir)[:values]["TRACKER_FILE"].to_s)
      turn_out = File.join(log_dir, "last_turn.out")
      log_text = Sys.read_scrubbed(log).to_s

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

    # Newest state line -> [node, merge_pr, merge_since].
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

    # Last turn line -> [turn_num, tier, model, thinking, task], including the
    # old-format fallback whose model regex stops at the first '-'
    # (`[^-[:space:]]+`) — kept as-is so logs written before the current turn
    # line format still parse.
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

    # Same-turn end line -> "took Ns" / "finished" / "running".
    def status_elapsed(log_text, turn_num)
      end_line = log_text.lines.select { |l| l =~ /\A\[[^\]]+\] turn \d+ end \| class=/ }.last
      return "running" unless end_line && end_line[/turn (\d+) end/, 1] == turn_num

      took = end_line[/took=(\d+)s/, 1]
      took ? "took #{took}s" : "finished"
    end

    # [done, open, total] as plain (non-heading-aware) line counts — "?"
    # triples when there is no tracker to count.
    def status_task_counts(tracker)
      return %w[? ? ?] unless File.file?(tracker)

      lines = File.readlines(tracker)
      done_n = lines.count { |l| l =~ /\A[[:space:]]*-?[[:space:]]*\[x\]/ }
      open_n = lines.count { |l| l =~ /\A[[:space:]]*-?[[:space:]]*\[( |IN PROGRESS)\]/ }
      [done_n, open_n, done_n + open_n]
    end

    # loop.pid -> [dot, status text].
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

    # last_turn.out -> the last non-blank summary line, handling both
    # plain-text agent output and the pi JSON stream (joining
    # text_delta fragments). ponytail: only \n, \t, \\ and \" are
    # unescaped from printf '%b' — full octal/hex escape support is not worth
    # it for a status preview line; widen if a real transcript needs it.
    # The agent's live prose: joined text_deltas for the pi JSON stream,
    # raw content otherwise. nil when there is nothing yet.
    # [rows, cols]; IO.console is nil without a TTY (tests, pipes), and
    # winsize can raise on exotic terminals — the fallback keeps the board
    # bounded either way.
    def term_size
      size = IO.console&.winsize
      size && size[0].to_i.positive? && size[1].to_i.positive? ? size : [24, 80]
    rescue StandardError
      [24, 80]
    end

    def turn_text(turn_out)
      return nil unless File.file?(turn_out) && !File.zero?(turn_out)

      content = File.read(turn_out)
      # The turn writes this file concurrently — the trailing line is usually
      # torn mid-write, and a torn delta line leaks JSON fragments into the
      # live board (watch reads this every 2s).
      unless content.end_with?("\n")
        lines = content.each_line.to_a
        lines.pop
        content = lines.join
      end
      if content.byteslice(0, 32).to_s.start_with?('{"type":"session"')
        content.each_line.grep(/"type":"text_delta"/)
                 .map { |l| l[/"delta":"((?:[^"\\]|\\.)*)"/, 1].to_s } # tolerates both the ","partial": suffix and a bare }}
                 .join.gsub('\\"', '"')
                 .gsub('\\n', "\n").gsub('\\t', "\t").gsub('\\\\', '\\')
      else
        content
      end
    end

    def status_doing_now(turn_out)
      t = turn_text(turn_out)
      t && Render.summary(t, 1)
    end

    # stdout only, never the loop log; a no-op under QUIET=1.
    def quiet? = @quiet == true
    def term_only(msg)
      return if @quiet

      puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}"
    end

    # Raw passthrough (no timestamp prefix), same QUIET gating as emit — for
    # multi-line agent excerpts.
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

    # Delegates to CommitGate, which owns the stage/exclude/scan/verify/commit
    # ordering; CLI supplies the loop.log
    # emit sink so the gate's prose lands in the same rendered log.
    def commit_turn(turn, model, conf, plan, dir)
      Robur::CommitGate.new(dir, plan: plan, config: conf, emit: method(:emit), loop_log: @loop_log)
                        .run(turn: turn, model: model)
    end

    # _turn_usage is DRY now: the loop reads Observability.turn_usage_detail
    # (cache-token fields) and keeps only this frozen TSV shape for metrics.tsv.
    def turn_usage(path)
      Observability.turn_usage(path)
    end

    # 12 frozen columns, plus the optional extension columns 13-15 when
    # `usage:` is given (Observability::METRICS_EXTENSION_COLUMNS documents
    # why).
    def metrics_append(repo_dir, event, turn, tier, model, klass, took, task, tin, tout, cost,
                       usage: nil)
      f = Paths.metrics_file
      FileUtils.mkdir_p(File.dirname(f))
      row = [Time.now.strftime("%F %T"), File.basename(repo_dir), event, turn, tier, model,
             klass, took, task, tin, tout, cost]
      row.concat(Observability.extension_columns(usage)) if usage
      File.write(f, "#{row.join("\t")}\n", mode: "a")
    rescue StandardError
      nil
    end

    # Integer mean of the took=Ns lines in loop.log.
    def avg_turn_secs(log)
      return 0 unless File.file?(log)

      vals = Sys.read_scrubbed(log).to_s.scan(/took=(\d+)s/).map { |m| m[0].to_i }
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

    # fanout/fanout-clean dispatch right after the log wiring and BEFORE the
    # run/once doctor preflight — neither is gated on preflight.
    def cmd_fanout(dir)
      dir = File.expand_path(dir || Dir.pwd)
      log_dir = File.join(Paths.logs_dir, project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")
      conf = Robur::Config.load(dir, @overrides || {}).values
      @quiet = conf["QUIET"] == "1"
      @loop_log = File.join(log_dir, "loop.log")
      Robur::Loop.fanout(dir, conf)
    end

    def cmd_fanout_clean(dir)
      dir = File.expand_path(dir || Dir.pwd)
      log_dir = File.join(Paths.logs_dir, project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")
      conf = Robur::Config.load(dir, @overrides || {}).values
      @quiet = conf["QUIET"] == "1"
      @loop_log = File.join(log_dir, "loop.log")
      Robur::Loop.fanout_clean(dir)
      0
    end

    # Shared run/once preflight: quiet doctor first, loud (re-run + print)
    # only on failure, abort before any turn.
    def cmd_run(dir)
      dir = File.expand_path(dir || Dir.pwd)
      wire_logs!(dir)
      @quiet = Robur::Config.load(dir, @overrides || {}).values["QUIET"] == "1"
      emit "preflight (doctor) ..."
      require "stringio"
      buf = StringIO.new
      problems = Commands.doctor_report(dir, out: buf)
      if problems.positive?
        emit "preflight FAILED — run '#{PROG} doctor #{dir}' for details. Aborting before any turn."
        print buf.string
        return 1
      end
      Robur::Loop.run(dir)
    end

    # `once`: quiet doctor first, loud only on failure, abort before any turn.
    # Then exactly ONE turn of the loop (banner, tier routing, watchdog run,
    # classify, metrics, per-outcome dispatch).
    def cmd_once(dir)
      dir = File.expand_path(dir || Dir.pwd)
      log_dir = File.join(Paths.logs_dir, project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")
      @quiet = Robur::Config.load(dir, @overrides || {}).values["QUIET"] == "1" # conf before preflight
      @loop_log = File.join(log_dir, "loop.log") # so preflight output is logged too
      emit "preflight (doctor) ..."
      require "stringio"
      buf = StringIO.new
      problems = Commands.doctor_report(dir, out: buf)
      if problems.positive?
        emit "preflight FAILED — run '#{PROG} doctor #{dir}' for details. Aborting before any turn."
        print buf.string
        exit 1
      end
      run_once_loop(dir)
    end

    module_function

    # One turn of the main loop, in --once mode.
    def run_once_loop(dir)
      conf = Robur::Config.load(dir, @overrides || {}).values
      plan = Plan.new(File.join(dir, conf["TRACKER_FILE"] || "PLAN.md"))
      models = Tier.chain_for("build", conf).to_s.split(",").reject(&:empty?)
      die "no models configured (-m chain, MODELS in #{Paths::REPO_CONF}, or global conf)." if models.empty?
      health = ModelHealth.new(conf)
      log_dir = File.dirname(@loop_log)
      obs = Observability.new(log_dir)
      turn_out = File.join(log_dir, "last_turn.out")
      run_start = mono
      run_toks = { in: 0, out: 0, cost: 0.0 }

      thinking_banner = conf["THINKING"].to_s.empty? ? "inherit" : conf["THINKING"]
      obs.emit(:run_start, repo: dir, session: "robur-#{project_slug(dir)} (resume=no)",
               tracker: conf["TRACKER_FILE"] || "PLAN.md", models: models,
               turn_timeout: conf["TURN_TIMEOUT"], cooldown: conf["COOLDOWN"],
               both_wait: conf["BOTH_WAIT"], step_token: conf["STEP_TOKEN"],
               done_token: conf["DONE_TOKEN"], agent_cmd: conf["AGENT_CMD"],
               thinking: thinking_banner, verify_cmd: conf["VERIFY_CMD"],
               commit_each_turn: conf["COMMIT_EACH_TURN"], push_on_done: conf["PUSH_ON_DONE"],
               open_pr: conf["OPEN_PR"], log_dir: log_dir)

      # write PID file so `robur status` can check liveness.
      File.write(File.join(log_dir, "loop.pid"), "#{Process.pid}\n")

      stop_reason = ""
      turn = 1
      last_model = "none"

      # All-done fast path: no open/in-progress tasks but at least one [x].
      if !plan.open? && !plan.in_progress? && plan.count(:done).positive?
        emit "all #{conf["TRACKER_FILE"] || "PLAN.md"} tasks complete (#{plan.count(:done)} done) — no open work remains."
        if commit_turn("final", last_model, conf, plan, dir).block_reason.nil?
          emit "agent signaled #{conf["DONE_TOKEN"]} — all work complete."
        end
        stop_reason = "done"
      else
        stop_reason, last_model = run_single_turn(dir, conf, plan, models, log_dir, turn_out,
                                                  run_toks, run_start, turn, obs)
      end

      obs.emit(:run_end, turns: turn)
      File.write(Paths.state_file(dir, "stop_reason"), "#{stop_reason}\n")
      state = File.file?(Paths.state_file(dir, "last_task.state")) ? File.read(Paths.state_file(dir, "last_task.state")) : ""
      taskid = state[/\A[^\t]*/].to_s
      metrics_append(dir, "run", "-", "-", last_model, stop_reason, elapsed_int(run_start), taskid,
                     run_toks[:in], run_toks[:out], format("%.6f", run_toks[:cost]))
      0 # exit code, not File.write's byte count
    end

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def elapsed_int(from) = (mono - from).to_i

    # Runs one turn and dispatches its outcome; returns [stop_reason, model].
    def run_single_turn(dir, conf, plan, models, log_dir, turn_out, run_toks, run_start, turn, obs)
      task = plan.next_task(:in_progress) || plan.next_task(:open)
      tag = task&.tags&.first
      tier = Tier.from_tag(tag)
      health = ModelHealth.new(conf)
      model = health.pick(models) || models.first
      thinking = Tier.thinking_for(tier, conf, model: model)
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

      obs.emit(:turn_start, turn: turn, model: model, tier: tier, thinking: thinking, task: next_task_str)

      Paths.loop_env_vars.each { |k| ENV[k] = "1" }
      turn_start = mono
      cmd = [conf["AGENT_CMD"], "--model", model] + Turn.mode_args(conf["AGENT_CMD"], kind: :step)
      cmd += ["--thinking", thinking] unless thinking.to_s.empty?
      # P0 fix: REAL prompt, not the literal string "turn" (see Loop.run).
      prompt = conf["PROMPT_OVERRIDE"].to_s.empty? ? Robur::Prompt.for_turn(conf: conf, plan: plan, log_dir: log_dir) : conf["PROMPT_OVERRIDE"]
      cmd += ["--no-session", "-p", prompt]
      result = Turn.run(cmd: cmd, turn_file: turn_out, chdir: dir,
                        turn_timeout: conf["TURN_TIMEOUT"].to_i,
                        stall_timeout: conf["STALL_TIMEOUT"].to_i,
                        poll_interval: (ENV["POLL_INTERVAL"] || conf["POLL_INTERVAL"] || 3).to_i,
                        early_tokens: [conf["STEP_TOKEN"], conf["DONE_TOKEN"]])
      status = result.kill_reason ? 128 + (result.status.termsig || 0) : result.status.exitstatus
      deadline = !result.kill_reason.nil? && result.kill_reason != "token-seen"
      klass = Classifier.classify(turn_out, step_token: conf["STEP_TOKEN"], done_token: conf["DONE_TOKEN"],
                                           deadline: deadline, json: Turn.pi_json?(conf["AGENT_CMD"]), human_token: conf["HUMAN_TOKEN"])
      took = elapsed_int(turn_start)
      obs.emit(:turn_end, turn: turn, class: klass, took: took, exitcode: status, task: next_task_str.slice(0, 20))

      detail = Observability.turn_usage_detail(turn_out)
      tin = detail[:input] + detail[:cache_read] + detail[:cache_write]
      tout = detail[:output]
      cost = format("%.6f", detail[:cost])
      metrics_append(dir, "turn", turn, tier, model, klass, took, taskid, tin, tout, cost,
                     usage: detail)
      run_toks[:in] += tin
      run_toks[:out] += tout
      run_toks[:cost] += detail[:cost]
      # fresh_in/tin/runaway ride on the event so token efficiency is
      # queryable from events.jsonl without recomputing it from the file.
      runaway = Observability.runaway?(detail)
      obs.emit_event(:tokens, input: detail[:input], output: detail[:output],
                        cache_read: detail[:cache_read], cache_write: detail[:cache_write],
                        fresh_in: detail[:input] + detail[:cache_write], tin: tin,
                        cost: detail[:cost], messages: detail[:messages], runaway: runaway)
      if runaway
        emit "turn #{turn}: #{detail[:messages]} agent round-trips (>= #{Observability.runaway_messages}) " \
             "for #{tout} output tokens — runaway tool loop; see #{turn_out}."
      end

      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last_task.state"), "#{taskid}\t#{klass}\n")

      avg = avg_turn_secs(@loop_log)
      eta = avg.zero? ? "ETA unknown" : "~#{open_n} turns / ~#{fmt_dur(open_n * avg)} left"
      term_only "  ⏱ turn #{turn} · #{fmt_dur(took)}   avg #{fmt_dur(avg)}   #{eta}"

      if !ENV.fetch("SUMMARY_LINES", "4").to_i.zero? && File.exist?(turn_out) && !File.zero?(turn_out)
        emit "--- summary ---"
        lines = File.read(turn_out).lines.reject { |l| l =~ /^[[:space:]]*$/ }
        lines.last(ENV.fetch("SUMMARY_LINES", "4").to_i).each { |l| flow l }
        emit "---"
      end

      # ALL_DONE with open tasks is mid-work, not done.
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
        health.bench!(model)
        emit "--once: stopping."
        return ["once", model]
      when :hard
        health.strike!(model)
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
      when :empty
        health.bench!(model)
        emit "model #{model} EMPTY OUTPUT (exit 0, nothing said) — benching #{conf["COOLDOWN"]}s, no strike."
        emit "--once: stopping."
        return ["once", model]
      else # :transient
        health.strike!(model)
        emit "model #{model} transient failure. strike 1/#{conf["MAX_TRANSIENT"]}; backing off #{conf["SHORT_SLEEP"]}s."
        emit "--once: stopping."
        return ["once", model]
      end
    end
  end
end
