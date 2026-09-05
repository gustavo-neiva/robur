# frozen_string_literal: true

require "fileutils"
require "open3"
require "robur/config"
require "robur/paths"
require "robur/plan"
require "robur/tier"
require "robur/turn"
require "robur/classifier"

module Robur
  # init | doctor | new | plan. PROG mirrors CLI::PROG so every "run: <prog>
  # ..." hint names the same binary the user typed.
  module Commands
    PROG = "robur"
    TEMPLATES_DIR = File.expand_path("../../templates", __dir__)

    module_function

    # detect_verify_cmd DIR -> proposes a green gate from the stack, or "".
    def detect_verify_cmd(dir)
      if File.file?(File.join(dir, "package.json"))
        File.read(File.join(dir, "package.json")).include?('"test"') ? "npm test" : 'node -e "console.log(1)"'
      elsif File.file?(File.join(dir, "mix.exs")) then "mix test"
      elsif File.file?(File.join(dir, "Cargo.toml")) then "cargo test"
      elsif File.file?(File.join(dir, "pyproject.toml")) || File.file?(File.join(dir, "pytest.ini")) then "pytest -q"
      elsif File.file?(File.join(dir, "Gemfile")) then "bundle exec rspec"
      elsif File.file?(File.join(dir, "go.mod")) then "go test ./..."
      else ""
      end
    end

    # detect_tracker_file DIR -> the tracker path (PLAN.md > TODO.md > TASKS.md), or "".
    def detect_tracker_file(dir)
      %w[PLAN.md TODO.md TASKS.md].find { |f| File.file?(File.join(dir, f)) } || ""
    end

    # ----------------------------- init ---------------------------------------
    def init(dir, emit: ->(m) { puts m })
      raise "not a directory: #{dir}" unless File.directory?(dir)

      conf = Paths.repo_conf(dir)
      emit.call("#{PROG} init: #{dir}")

      if File.file?(conf)
        emit.call("  #{File.basename(conf)} exists — leaving it (re-stamp only)")
      else
        FileUtils.cp(File.join(TEMPLATES_DIR, "robur.conf.example"), conf)
        seed_vc = detect_verify_cmd(dir)
        if seed_vc.empty?
          # The template's VERIFY_CMD stays: doctor FAILs on an empty one, so a
          # bare repo would fail its own first doctor. The placeholder is loud
          # in its own way — say what actually happened, not "left empty".
          emit.call("  no stack detected -> VERIFY_CMD left at the template default (set it; no-gate is loud by design)")
        else
          emit.call("  detected stack -> VERIFY_CMD='#{seed_vc}'")
          File.write(conf, File.read(conf).sub(/^VERIFY_CMD=.*$/, "VERIFY_CMD=#{seed_vc}"))
        end
      end

      # Leave `.ratchet.conf` pointing at the new conf. A directory symlink
      # covers the state dir, but a plain file has no shim, and the nightly
      # supervisor decides whether a repo is runnable by testing for
      # `.ratchet.conf` — without this a freshly initialised repo is silently
      # never picked up.
      Paths.ensure_repo_conf_link!(dir)

      values, errors = Config.parse_repo(File.read(conf))
      unless errors.empty?
        emit.call("  WARNING: #{File.basename(conf)} has errors:")
        emit.call(errors.join("\n"))
      end
      tr = values["TRACKER_FILE"]
      tr = detect_tracker_file(dir) if tr.to_s.empty?
      tr = "PLAN.md" if tr.to_s.empty?

      unless File.file?(File.join(dir, tr))
        FileUtils.cp(File.join(TEMPLATES_DIR, "PLAN.seed.md"), File.join(dir, tr))
        emit.call("  seeded #{tr} (edit it, or run '#{PROG} new' to draft from an idea)")
      end

      learnings = File.join(dir, "LEARNINGS.md")
      FileUtils.cp(File.join(TEMPLATES_DIR, "LEARNINGS.md"), learnings) unless File.file?(learnings)

      migrated = migrate_agents_md(dir)
      seed_agents_md(dir, migrated, emit)

      gitignore_audit(dir)

      Config.write_conf_hash(dir)

      emit.call("done. Next: review #{tr}, then '#{PROG} doctor #{dir}' and '#{PROG} run #{dir}'.")
    end

    # Strips a legacy loop-protocol block from AGENTS.md: drop the lines
    # between the begin/end markers, preserve everything else verbatim. Both
    # the current and the pre-rename marker names are recognised so a repo
    # stamped before the rename still migrates. Returns true if a migration
    # happened.
    PROTOCOL_MARKER = /(?:robur|ratchet)-protocol:/

    def migrate_agents_md(dir)
      agents = File.join(dir, "AGENTS.md")
      return false unless File.file?(agents) && File.read(agents) =~ /#{PROTOCOL_MARKER}.*:begin/

      skip = false
      kept = File.readlines(agents).each_with_object(+"") do |line, out|
        if line =~ /#{PROTOCOL_MARKER}.*:begin/
          skip = true
        elsif line =~ /#{PROTOCOL_MARKER}.*:end/
          skip = false
        elsif !skip
          out << line
        end
      end
      File.write(agents, kept)
      true
    end

    def seed_agents_md(dir, migrated, emit)
      agents = File.join(dir, "AGENTS.md")
      return if File.file?(agents) && !File.zero?(agents) && File.read(agents) =~ /\S/

      FileUtils.cp(File.join(TEMPLATES_DIR, "AGENTS.human.md"), agents)
      emit.call(migrated ? "  seeded human AGENTS.md (no content after marker strip)" : "  seeded human AGENTS.md")
    end

    def gitignore_audit(dir)
      gi = File.join(dir, ".gitignore")
      File.write(gi, "") unless File.file?(gi)
      existing = File.readlines(gi, chomp: true)
      # The legacy names stay listed: `Paths.ensure_state_dir!` leaves
      # `.ratchet` as a symlink, and an un-migrated repo still has the old
      # conf — neither should ever be committed.
      ["#{Paths::STATE_DIR}/", Paths::REPO_CONF, "#{Paths::LEGACY_STATE_DIR}/",
       Paths::LEGACY_REPO_CONF].each do |line|
        next if existing.include?(line)

        File.write(gi, "#{line}\n", mode: "a")
        existing << line
      end
    end

    # ----------------------------- doctor -------------------------------------
    # The doctor body, printable to any IO so `once` can run it quiet first.
    def doctor_report(dir, out: $stdout)
      problems = 0
      pr_ok = ->(m) { out.puts "  ok   #{m}" }
      pr_fail = lambda do |m|
        out.puts "  FAIL #{m}"
        problems += 1
      end

      slug = CLI.project_slug(dir)
      log_dir = File.join(Paths.logs_dir, slug)
      FileUtils.mkdir_p(log_dir)
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")

      out.puts "doctor: #{dir}"

      mid_operation_check(dir, pr_fail)

      conf_path = Paths.repo_conf(dir)
      conf_values = {}
      conf_errors = []
      conf_values, conf_errors = Config.parse_repo(File.read(conf_path)) if File.file?(conf_path)

      pr_ok.call("git repo") if File.directory?(File.join(dir, ".git"))
      agent = conf_values["AGENT_CMD"] || "pi"
      if CLI.on_path?(agent)
        pr_ok.call("agent command '#{agent}' on PATH")
      else
        pr_fail.call("agent command '#{agent}' not found (set AGENT_CMD / install it)")
      end

      if File.file?(conf_path)
        if conf_errors.empty?
          pr_ok.call("#{File.basename(conf_path)} parses (allowlisted keys)")
        else
          pr_fail.call("#{File.basename(conf_path)} has errors:")
          out.puts ("\n" + conf_errors.join("\n")).gsub(/^/, "         ")
        end
        # Either spelling of the protocol key is honoured; a repo conf written
        # before the rename must not start failing doctor.
        protocol_key = conf_values.key?("ROBUR_PROTOCOL") ? "ROBUR_PROTOCOL" : "RATCHET_PROTOCOL"
        case conf_values[protocol_key] || "1"
        when "1" then pr_ok.call("#{protocol_key}=1 supported")
        else pr_fail.call("#{protocol_key}=#{conf_values[protocol_key]} unsupported (want 1)")
        end
        conf_hash_check(dir, conf_path, pr_ok, pr_fail)
      else
        pr_fail.call("no #{Paths::REPO_CONF} (run: #{PROG} init #{dir})")
      end

      agents = File.join(dir, "AGENTS.md")
      if File.file?(agents) && File.read(agents) =~ /#{PROTOCOL_MARKER}.*:begin/
        pr_fail.call("AGENTS.md carries a legacy loop-in-file protocol block; run `#{PROG} init #{dir}` to migrate (loop protocol now travels in the harness prompt)")
      else
        pr_ok.call("protocol delivery: harness-prompt (loop briefs its own turns)")
      end

      # TRACKER_FILE first, autodetect only as the fallback: doctor used to
      # hardcode the autodetect list, so a repo whose conf pointed the loop at
      # another tracker got a green report about a file the loop never reads.
      tr = conf_values["TRACKER_FILE"].to_s
      tr = %w[PLAN.md TODO.md TASKS.md].find { |f| File.file?(File.join(dir, f)) } if tr.empty?
      tr = nil unless tr && File.file?(File.join(dir, tr))
      if tr
        plan = Plan.new(File.join(dir, tr))
        content = File.read(File.join(dir, tr))
        if content =~ /^[[:space:]]*-?[[:space:]]*\[ \]/
          pr_ok.call("tracker '#{tr}' has an open task")
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
        pr_fail.call("VERIFY_CMD is EMPTY — set it in #{Paths::REPO_CONF} (no-gate is loud by design)")
      else
        pr_ok.call("VERIFY_CMD is set: '#{verify_cmd}'")
        first = verify_cmd.split[0]
        builtins = %w[if then else elif fi for while do done case esac function return continue break :]
        if !builtins.include?(first) && !CLI.on_path?(first) && !File.readable?(File.join(dir, first))
          pr_fail.call("VERIFY_CMD references unresolved executable: '#{first}' (not found via command -v or as file)")
        end
      end

      pr_ok.call("tokens: defined in conf (prompt delivery)")

      if CLI.on_path?("gitleaks")
        pr_ok.call("gitleaks available (rich secret scan)")
      else
        pr_ok.call("gitleaks missing — builtin pattern scan will run (install gitleaks for more)")
      end

      required_tools_check(conf_values, pr_ok, pr_fail)

      pr_ok.call("pi registry cache missing/stale — model validation skipped (refresh: #{PROG} models list)")
      pr_ok.call("rank source: none (unranked no-join: 0)")

      out.puts "---"
      tier_routing_report(out, conf_values)

      out.puts "---"
      if problems.zero?
        out.puts "doctor: OK — repo is loop-ready."
      else
        out.puts "doctor: #{problems} problem(s). Fix before running the loop."
      end
      problems
    end

    def mid_operation_check(dir, pr_fail)
      git = File.join(dir, ".git")
      if File.directory?(File.join(git, "rebase-merge"))
        pr_fail.call("repo is mid-rebase (interactive) — use 'git rebase --quit' to keep commits or 'git rebase --abort' to discard")
      elsif File.directory?(File.join(git, "rebase-apply"))
        pr_fail.call("repo is mid-rebase (apply) — use 'git rebase --quit' or 'git am --abort'")
      elsif File.file?(File.join(git, "MERGE_HEAD"))
        pr_fail.call("repo is mid-merge — resolve conflicts and commit, or 'git merge --abort'")
      elsif File.file?(File.join(git, "CHERRY_PICK_HEAD"))
        pr_fail.call("repo is mid-cherry-pick — resolve and commit, or 'git cherry-pick --abort'")
      end
    end

    def conf_hash_check(dir, conf_path, pr_ok, pr_fail)
      hash_file = Paths.state_file(dir, "conf.hash")
      return unless File.file?(hash_file)

      if Config.conf_hash(conf_path) == File.read(hash_file).strip
        pr_ok.call("#{File.basename(conf_path)} unchanged since onboarding")
      else
        pr_fail.call("#{File.basename(conf_path)} CHANGED since onboarding — review & re-acknowledge (run: #{PROG} init #{dir})")
      end
    end

    def required_tools_check(conf_values, pr_ok, pr_fail)
      required = conf_values["REQUIRED_TOOLS"].to_s
      return if required.empty?

      tools = required.split(",").map(&:strip).reject(&:empty?)
      missing = tools.reject { |t| CLI.on_path?(t) }
      if missing.empty?
        pr_ok.call("all required tools available: #{required}")
      else
        pr_fail.call("missing required tool(s):#{missing.map { |t| " #{t}" }.join} (install them or remove from REQUIRED_TOOLS in #{Paths::REPO_CONF})")
      end
    end

    def tier_routing_report(out, conf_values)
      out.puts "tier routing:"
      display_tier(out, "PLAN  ", "plan", "MODELS (flat)", "PLAN_MODELS", conf_values)
      display_tier(out, "AUTOPL", "autoplan", "PLAN", "AUTOPLAN_MODELS", conf_values)
      display_tier(out, "BUILD ", "build", "MODELS (flat)", "BUILD_MODELS", conf_values)
      display_tier(out, "LIGHT ", "light", "MODELS (flat)", "LIGHT_MODELS", conf_values)

      plan_think = Tier.thinking_for("plan", conf_values)
      light_think = Tier.thinking_for("light", conf_values)
      if conf_values["AUTOPLAN_MODELS"].to_s.empty? && !conf_values["PLAN_MODELS"].to_s.empty?
        out.puts "  WARN : AUTOPLAN_MODELS unset — scheduled `plan --auto` turns burn the PLAN chain (#{Tier.chain_for("plan", conf_values)})"
      end
      if !conf_values["LIGHT_MODELS"].to_s.empty? && light_think != "off"
        out.puts '  WARN : LIGHT_MODELS set but THINKING_LIGHT is not "off" (cheap tier should not reason)'
      end
    end

    def display_tier(out, label, tier, fallback_label, conf_key, conf_values)
      think = Tier.thinking_for(tier, conf_values)
      if conf_values[conf_key].to_s.empty?
        out.puts "  #{label}: → #{fallback_label} (thinking=#{think})"
      else
        out.puts "  #{label}: #{Tier.chain_for(tier, conf_values)} (thinking=#{think})"
      end
    end

    # ----------------------------- new ----------------------------------------
    def new_repo(idea, dir, emit: ->(m) { puts m })
      raise "usage: #{PROG} new \"<idea>\" [DIR]" if idea.to_s.empty?

      name = idea.downcase.tr(" ", "-").gsub(/[^a-z0-9-]/, "").sub(/\A-+/, "").sub(/-+\z/, "").gsub(/-{2,}/, "-")
      name = "new-repo" if name.empty?
      dir ||= File.join(Dir.pwd, name)
      emit.call("#{PROG} new: '#{idea}' -> #{dir}")
      FileUtils.mkdir_p(dir)
      Open3.capture3("git", "init", "-q", chdir: dir)

      File.write(File.join(dir, "BRIEF.md"), <<~BRIEF)
        # Brief: #{idea}

        ## What
        #{idea}

        ## Definition of done
        - _(replace: what must be true for this to ship?)_

        ## Non-goals
        - _(explicitly out of scope)_

        ## Constraints / stack
        - _(language, runtime, target, anything load-bearing)_
      BRIEF
      emit.call("  wrote BRIEF.md")

      init(dir, emit: emit)

      tracker_file = detect_tracker_file(dir)
      tracker_file = "PLAN.md" if tracker_file.empty?
      File.write(File.join(dir, tracker_file), <<~PLAN)
        # Plan — #{idea}

        > Drafted from BRIEF.md. **Review this before running the loop** — this is the
        > one mandatory human checkpoint. Edit freely.

        ## Milestone 0 — Walking skeleton + green gate
        - [ ] T0.1 (trivial) scaffold project from the constraints in BRIEF.md
        - [ ] T0.2 (normal) verify command is green (one passing walking-skeleton test)
        - [ ] T0.3 (normal) thinnest end-to-end slice

        ## Milestone 1 — _(flesh out from the brief)_
        - [ ] T1.1 (normal) _(first real task toward the definition of done)_

        ## Non-goals
        - _(copy from BRIEF.md)_
      PLAN
      emit.call("  drafted #{tracker_file}")

      Open3.capture3("git", "-C", dir, "add", "-A")
      _out, _err, status = Open3.capture3("git", "-C", dir, "commit", "-q", "-m", "scaffold: #{idea} (#{PROG} new)")
      emit.call("  initial commit") if status.success?

      emit_plan_review_stop(emit, dir, tracker_file,
                             "  1. Open #{dir}/#{tracker_file} and #{dir}/BRIEF.md.",
                             "  2. Edit the plan until Milestone 0 + the feature milestones are right.",
                             "  3. Commit your edits, then:  #{PROG} doctor #{dir} && #{PROG} run #{dir}")
    end

    def emit_plan_review_stop(emit, _dir, _tracker, *lines)
      emit.call("")
      emit.call("STOP FOR PLAN REVIEW (mandatory human checkpoint):")
      lines.each { |l| emit.call(l) }
      emit.call("  (#{PROG} never auto-runs the loop after a plan — you review first.)")
    end

    # ----------------------------- plan ---------------------------------------
    # ONE plan-drafting turn, then STOP for human review (unless auto). Commits
    # ONLY the tracker + LEARNINGS.md — a plan turn never lands code.
    def plan(dir, conf, auto: false, turn_out:, emit: ->(m) { puts m })
      if auto
        emit.call("#{PROG} plan --auto: #{dir} (AUTOPLAN tier — ONE unattended turn)")
        plan_turn(dir, conf, auto: true, turn_out: turn_out, emit: emit)
        return
      end
      emit.call("#{PROG} plan: #{dir} (PLAN tier — ONE turn, then STOP for review)")
      tracker_file = plan_turn(dir, conf, auto: false, turn_out: turn_out, emit: emit)
      emit_plan_review_stop(emit, dir, tracker_file,
                             "  HUMAN: review #{dir}/#{tracker_file} before running the loop.",
                             "  Edit the plan (Milestone 0 + tags), then: #{PROG} doctor #{dir} && #{PROG} run #{dir}")
    end

    def plan_turn(dir, conf, auto:, turn_out:, emit:)
      tracker_file = conf["TRACKER_FILE"]
      tracker_file = detect_tracker_file(dir) if tracker_file.to_s.empty?
      tracker_file = "PLAN.md" if tracker_file.to_s.empty?
      tracker_path = File.join(dir, tracker_file)
      raise "no tracker '#{tracker_file}' in #{dir} (run '#{PROG} init #{dir}' first)." unless File.file?(tracker_path)

      tier = auto ? "autoplan" : "plan"
      chain = Tier.chain_for(tier, conf).to_s.split(",").reject(&:empty?)
      raise "no model for #{tier} tier (set AUTOPLAN_MODELS / PLAN_MODELS / MODELS / -m)." if chain.empty?

      model = chain.first
      thinking = Tier.thinking_for(tier, conf)
      prompt = build_plan_prompt(tracker_path, tracker_file, conf["STEP_TOKEN"])

      emit.call("plan turn 1 | tier=#{tier} | model=#{model} | thinking=#{thinking}")
      cmd = [conf["AGENT_CMD"], "--model", model] + Turn.mode_args(conf["AGENT_CMD"], kind: :plan)
      cmd += ["--thinking", thinking] unless thinking.to_s.empty?
      cmd += ["--no-session", "-p", prompt]

      # Exported for EVERY turn (build/plan/review alike) — the agent's
      # protocol reads it to know it is loop-driven.
      Paths.loop_env_vars.each { |k| ENV[k] = "1" }
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Turn.run(cmd: cmd, turn_file: turn_out, chdir: dir,
                        turn_timeout: conf["TURN_TIMEOUT"].to_i,
                        stall_timeout: conf["STALL_TIMEOUT"].to_i,
                        poll_interval: (conf["POLL_INTERVAL"] || 3).to_i)
      took = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to_i
      deadline = !result.kill_reason.nil?
      step_token = conf["STEP_TOKEN"].to_s.empty? ? Config::DEFAULTS["STEP_TOKEN"] : conf["STEP_TOKEN"]
      done_token = conf["DONE_TOKEN"].to_s.empty? ? Config::DEFAULTS["DONE_TOKEN"] : conf["DONE_TOKEN"]
      human_token = conf["HUMAN_TOKEN"].to_s.empty? ? Config::DEFAULTS["HUMAN_TOKEN"] : conf["HUMAN_TOKEN"]
      klass = Classifier.classify(turn_out, step_token: step_token, done_token: done_token,
                                           deadline: deadline, json: Turn.pi_json?(conf["AGENT_CMD"]), human_token: human_token)
      emit.call("plan turn 1 end | class=#{klass} | took=#{took}s")

      if !ENV.fetch("SUMMARY_LINES", "4").to_i.zero? && File.exist?(turn_out) && !File.zero?(turn_out)
        emit.call("--- summary ---")
        lines = File.read(turn_out).lines.reject { |l| l =~ /^[[:space:]]*$/ }
        lines.last(ENV.fetch("SUMMARY_LINES", "4").to_i).each { |l| CLI.flow(l) }
        emit.call("---")
      end

      plan_commit(dir, tracker_file, conf, emit)
      tracker_file
    end

    # build_plan_prompt: draft/refresh open tasks; build_ktlo_prompt when the
    # tracker has no open work left (a caught-up repo grooms itself).
    def build_plan_prompt(tracker_path, tracker_file, step_token)
      return build_ktlo_prompt(tracker_file, step_token) unless File.read(tracker_path) =~ /^- \[ \]/

      "You are doing a PLAN-drafting turn (robur plan), not implementation. Read this repository, read #{tracker_file}, and draft or refresh the open tasks so the plan is concrete and actionable. Rules: keep a Milestone 0 walking skeleton whose verify gate is green; ASSIGN a tier tag (trivial|normal|hard) to EVERY task as you write it, with a one-line justification for any non-obvious choice; make each task ONE discrete step; size each milestone as ONE human-reviewable unit (a coherent feature/subfeature, target under ~400 changed lines of implementation) because milestones are the review/PR boundary; the FIRST line of the tracker must be a class marker, `<!-- class: MACHINE -->` or `<!-- class: HUMAN -->` — HUMAN when the plan involves money movement, strategy pivots, outward-facing launches, or taste-heavy product calls, MACHINE for internal tooling under green gates, and MACHINE when unsure; do NOT write or change code in this turn — only #{tracker_file} and LEARNINGS.md. When you have finished drafting/refreshing the plan, print the token #{step_token} on its own line and STOP. Do not run the build loop."
    end

    def build_ktlo_prompt(tracker_file, step_token)
      "You are doing a KTLO PLAN-drafting turn (robur plan) on a repository with NO open tasks left. It is caught up, so your job is to source keep-the-lights-on and self-improvement work, not new features. Read this repository, read #{tracker_file} (the completed plan), read LEARNINGS.md, and read recent git history. Draft the next milestone ONLY from these sources: (1) dependency freshness and security advisories; (2) flaky, slow, skipped, or missing tests, especially covering the most recently completed milestones; (3) LEARNINGS.md entries that describe a recurring gotcha no test or guard yet prevents; (4) dead code, unused config keys, and duplicated logic that a single shared function would remove; (5) documentation drift where README/AGENTS.md contradicts current behaviour; (6) error paths and edge cases in recently added code that the verify gate does not yet exercise. Hard rules: propose NO new features, NO speculative abstractions, and NO refactors without a behavioural test that would catch a regression; EVERY task must be verifiable by this repo VERIFY_CMD gate, so if you cannot state how the gate proves it, drop it; prefer deleting code over adding it. Keep the milestone SMALL: at most 5 tasks, target under ~400 changed lines total. Tag EVERY task (trivial|normal|hard). Keep the class marker on the FIRST line of the tracker (`<!-- class: MACHINE -->` for maintenance work). If, after genuinely checking all six sources, there is nothing worth doing, write NOTHING to the tracker and say so plainly — an honest empty plan is a correct outcome and beats invented work. Do NOT write or change code in this turn — only #{tracker_file} and LEARNINGS.md. When done, print the token #{step_token} on its own line and STOP. Do not run the build loop."
    end

    # plan_commit: commit ONLY the tracker + LEARNINGS.md. No `git add -A`, no
    # verify gate (the tree may legitimately be RED while planning), no
    # contract-tamper guard (plan never stages the repo conf or AGENTS.md).
    def plan_commit(dir, tracker_file, conf, emit)
      return unless conf["COMMIT_EACH_TURN"] == "1"
      return unless File.directory?(File.join(dir, ".git"))

      Open3.capture3("git", "-C", dir, "add", "--", tracker_file, "LEARNINGS.md")
      _out, _err, status = Open3.capture3("git", "-C", dir, "diff", "--cached", "--quiet")
      if status.success?
        emit.call("  nothing plan-staged to commit (idempotent plan turn).")
        return
      end
      _out2, _err2, commit_status = Open3.capture3("git", "-C", dir, "commit", "-q", "-m", "plan(#{Paths::COMMIT_SCOPE}): refresh #{tracker_file}")
      if commit_status.success?
        emit.call("  plan-committed: #{tracker_file} (+ LEARNINGS.md if changed)")
      else
        emit.call("  plan git commit failed — continuing.")
      end
    end
  end
end
