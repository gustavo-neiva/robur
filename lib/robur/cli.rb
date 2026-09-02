# frozen_string_literal: true

require "fileutils"

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

    def emit(msg)
      puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}"
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
      8.times { upd.call(len & 0xFF); len >>= 8 }
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

    def run(argv)
      command = nil
      dir = nil
      argv.each do |a|
        case a
        when "-h", "--help" then usage; return 0
        when /\A-/ then die("unknown option: #{a} (see --help)")
        when "doctor" then command = a
        else dir ||= a
        end
      end

      case command
      when "doctor" then cmd_doctor(File.expand_path(dir || Dir.pwd))
      else die("unknown command: #{command.inspect}")
      end
    end

    # ponytail: only the no-.ratchet.conf doctor path is ported (the only one
    # the M1 suite exercises); conf-parsing checks arrive with the Config port.
    def cmd_doctor(dir)
      problems = 0
      pr_ok = ->(m) { puts "  ok   #{m}" }
      pr_fail = lambda do |m|
        puts "  FAIL #{m}"
        problems += 1
      end

      # wire up logs like main() does before dispatch, so last-log exists
      slug = project_slug(dir)
      log_dir = File.join(ratchet_home, "logs", slug)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(File.join(dir, ".ratchet"))
      File.write(File.join(dir, ".ratchet", "last-log"), "#{log_dir}\n")

      puts "doctor: #{dir}"

      pr_ok.call("git repo") if File.directory?(File.join(dir, ".git"))

      # common.sh force-assigns AGENT_CMD="pi", clobbering any env value.
      if on_path?("pi")
        pr_ok.call("agent command 'pi' on PATH")
      else
        pr_fail.call("agent command 'pi' not found (set AGENT_CMD / install it)")
      end

      # conf parses (PARSED, never sourced — see Robur::Config trust boundary)
      conf_path = File.join(dir, ".ratchet.conf")
      conf_values = {}
      if File.file?(conf_path)
        conf_values, cerr = Robur::Config.parse_repo(File.read(conf_path))
        if cerr.empty?
          pr_ok.call(".ratchet.conf parses (allowlisted keys)")
        else
          pr_fail.call(".ratchet.conf has errors:")
          puts cerr.join("\n").gsub(/^/, "         ")
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
        if File.read(File.join(dir, tr)) =~ /^- \[ \]/
          pr_ok.call("tracker '#{tr}' has an open task")
        elsif File.read(File.join(dir, tr)) =~ /^- \[x\]/
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
      end

      pr_ok.call("tokens: defined in conf (prompt delivery)")

      if on_path?("gitleaks")
        pr_ok.call("gitleaks available (rich secret scan)")
      else
        pr_ok.call("gitleaks missing — builtin pattern scan will run (install gitleaks for more)")
      end

      pr_ok.call("pi registry cache missing/stale — model validation skipped (refresh: #{PROG} models list)")
      pr_ok.call("rank source: none (unranked no-join: 0)")

      puts "---"
      puts "tier routing:"
      puts "  PLAN  : → MODELS (flat) (thinking=)"
      puts "  AUTOPL: → PLAN (thinking=)"
      puts "  BUILD : → MODELS (flat) (thinking=)"
      puts "  LIGHT : → MODELS (flat) (thinking=)"
      puts "---"
      if problems.zero?
        puts "doctor: OK — repo is loop-ready."
      else
        puts "doctor: #{problems} problem(s). Fix before running the loop."
      end
      exit problems
    end
  end
end
