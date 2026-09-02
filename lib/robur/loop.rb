# frozen_string_literal: true

require "json"
require "open3"
require "robur/config"
require "robur/plan"
require "robur/tier"
require "robur/model_chain"
require "robur/turn"
require "robur/classifier"
require "robur/commit_gate"
require "robur/cli"
require "robur/repo"
require "robur/sys"
require "robur/state"
require "robur/commands"

module Robur
  # The unattended run loop (port of bin/ratchet main's while-true cycle).
  # Shares CLI's emit/commit_turn/metrics helpers (same loop.log surface);
  # sleep is injectable so the all-benched ladder is testable.
  module Loop
    BACKOFF_LADDER = [900, 3600, 14400].freeze

    module_function

    # Full `robur run`. Returns the process exit code (0 on a clean stop).
    def run(dir, once: false, sleep_it: Kernel.method(:sleep))
      dir = File.expand_path(dir)
      conf = Robur::Config.load(dir, {}).values
      log_dir = File.join(CLI.ratchet_home, "logs", CLI.project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(File.join(dir, ".ratchet"))
      File.write(File.join(dir, ".ratchet", "last-log"), "#{log_dir}\n")
      CLI.instance_variable_set(:@quiet, conf["QUIET"] == "1")
      CLI.instance_variable_set(:@loop_log, File.join(log_dir, "loop.log"))

      plan = Plan.new(File.join(dir, conf["TRACKER_FILE"] || "PLAN.md"))
      flat = conf["MODELS"].to_s.split(",").reject(&:empty?)
      CLI.die "no models configured (-m chain, MODELS in .ratchet.conf, or global conf)." if flat.empty?

      turn_out = File.join(log_dir, "last_turn.out")
      run_start = CLI.mono
      run_toks = { in: 0, out: 0, cost: 0.0 }
      turn = 0
      last_model = "none"
      done_gate_fails = 0
      all_benched_count = 0
      current_tier_chain = ""
      stop_reason = ""
      # per-model transient strikes live on ONE chain keyed by chain string;
      # a tier switch to an equal chain keeps them (bash reinit-on-change).
      chains = {}

      emit = ->(m) { CLI.emit(m) }

      session_id = conf["SESSION_NAME"].to_s.empty? ? "ratchet-#{CLI.project_slug(dir)}" : "ratchet-#{conf["SESSION_NAME"]}"
      resume = conf["RESUME_SESSION"] == "1" ? "yes" : "no"
      thinking_banner = conf["THINKING"].to_s.empty? ? "inherit" : conf["THINKING"]

      emit "=" * 60
      emit "ratchet START"
      emit "  repo      : #{dir}"
      emit "  session   : #{session_id} (resume=#{resume})"
      emit "  tracker   : #{conf["TRACKER_FILE"] || "PLAN.md"}"
      emit "  models    : #{flat.join(" ")}  (preference order, fallback chain)"
      emit "  turn cap  : #{conf["TURN_TIMEOUT"]}s   cooldown: #{conf["COOLDOWN"]}s   both-wait: #{conf["BOTH_WAIT"]}s"
      emit "  tokens    : step='#{conf["STEP_TOKEN"]}'  done='#{conf["DONE_TOKEN"]}'"
      emit "  agent     : #{conf["AGENT_CMD"]}"
      emit "  thinking  : #{thinking_banner}"
      emit "  verify    : #{conf["VERIFY_CMD"].to_s.empty? ? "<EMPTY — loud warning, no gate>" : conf["VERIFY_CMD"]}"
      emit "  commit    : per-turn=#{conf["COMMIT_EACH_TURN"] == "1" ? "yes" : "no"}  push-on-done=#{conf["PUSH_ON_DONE"] == "1" ? "yes" : "no"}  pr=#{conf["OPEN_PR"] == "1" ? "yes" : "no"}"
      emit "  loop log  : #{log_dir}/loop.log"
      emit "  stop      : Ctrl-C"
      emit "=" * 60

      exit_code = auto_plan_pr0(dir, conf, plan, turn_out, File.join(log_dir, "loop.log"), sleep_it: sleep_it)
      return exit_code if exit_code

      milestone_branch_lifecycle(dir, conf, plan)

      # write PID file (bin/ratchet:511) so `ratchet status` can check liveness.
      File.write(File.join(log_dir, "loop.pid"), "#{Process.pid}\n")

      loop do
        turn += 1

        # All-done fast path: no open/in-progress but has [x].
        if !plan.open? && !plan.in_progress? && plan.count(:done).positive?
          emit "all #{conf["TRACKER_FILE"] || "PLAN.md"} tasks complete (#{plan.count(:done)} done) — no open work remains."
          if commit_turn("final", last_model, conf, plan, dir).block_reason.nil?
            emit "agent signaled #{conf["DONE_TOKEN"]} — all work complete."
          else
            emit "final commit gate RED — staged work left for human review."
          end
          stop_reason = "done"
          break
        end

        # Tier routing: reinit the chain ONLY when the tier's chain changes
        # (preserves bench/strike state within a tier).
        tag = plan.next_task(:in_progress)&.tags&.first || plan.next_task(:open)&.tags&.first
        tier = Tier.from_tag(tag, cheap: conf["CHEAP_MODE"] == "1")
        tier_chain = Tier.chain_for(tier, conf).to_s
        tier_chain = flat.join(",") if tier_chain.empty?
        if tier_chain != current_tier_chain
          chains[tier_chain] ||= ModelChain.new(tier_chain.split(",").reject(&:empty?), conf,
                                                clock: Sys::Clock.new,
                                                max_transient: conf["MAX_TRANSIENT"].to_i)
          current_tier_chain = tier_chain
        end
        chain = chains.fetch(current_tier_chain)
        idx = chain.pick
        if idx.nil?
          # Tier chain exhausted: fall back to the flat MODELS chain for one turn.
          if current_tier_chain != flat.join(",")
            emit "tier (#{tier}) chain exhausted — falling back to MODELS for this turn."
            current_tier_chain = flat.join(",")
            chains[current_tier_chain] ||= ModelChain.new(flat, conf, clock: Sys::Clock.new,
                                                                   max_transient: conf["MAX_TRANSIENT"].to_i)
            chain = chains.fetch(current_tier_chain)
            idx = chain.pick
          end
          if idx.nil?
            # ALL models benched: ladder backoff, reset, retry.
            all_benched_count += 1
            backoff = BACKOFF_LADDER[all_benched_count - 1] || BACKOFF_LADDER.last
            emit "ALL models benched (exhausted), attempt #{all_benched_count}. Sleeping #{backoff}s, then reset + retry."
            sleep_it.call(backoff)
            chains.each_value(&:reset_all)
            current_tier_chain = ""
            next
          end
        end

        model = chain.models[idx]
        last_model = model
        thinking = Tier.thinking_for(tier, conf)

        task = plan.next_task(:in_progress) || plan.next_task(:open)
        next_task_str = task ? "#{task.id} (#{task.tags.join(", ")}) #{task.text}" : ""
        done_n = plan.count(:done)
        open_n = plan.count(:open) + plan.count(:in_progress)
        emit "tasks: #{done_n} done / #{done_n + open_n} total | next: #{next_task_str.slice(0, 60)}"

        emit "--- turn #{turn} | model=#{model} ---"
        emit "turn #{turn} | tier=#{tier} | model=#{model} | thinking=#{thinking} | task=#{next_task_str}"

        ENV["RATCHET_LOOP"] = "1"
        turn_start = CLI.mono
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
        took = CLI.elapsed_int(turn_start)
        emit "turn #{turn} end | class=#{klass} | took=#{took}s | exitcode=#{status} | task=#{next_task_str.slice(0, 20)}"

        tin, tout, cost = CLI.turn_usage(turn_out).split("\t")
        CLI.metrics_append(dir, "turn", turn, tier, model, klass, took, task ? task.id : "?", tin, tout, cost)
        run_toks[:in] += tin.to_i
        run_toks[:out] += tout.to_i
        run_toks[:cost] += cost.to_f

        FileUtils.mkdir_p(File.join(dir, ".ratchet"))
        File.write(File.join(dir, ".ratchet", "last_task.state"), "#{task ? task.id : "?"}\t#{klass}\n")

        # show_excerpt (observability.sh:41)
        if !ENV.fetch("SUMMARY_LINES", "4").to_i.zero? && File.exist?(turn_out) && !File.zero?(turn_out)
          emit "--- summary ---"
          lines = File.read(turn_out).lines.reject { |l| l =~ /^[[:space:]]*$/ }
          lines.last(ENV.fetch("SUMMARY_LINES", "4").to_i).each { |l| CLI.flow(l) }
          emit "---"
        end

        # sanity-gate BEFORE the case: done-with-open-tasks is mid-work. Setting
        # the status inside a `done` arm would never re-dispatch (the bash bug
        # that exited with open tasks) — downgrade here instead.
        if klass == :done && (plan.open? || plan.in_progress?)
          emit "agent printed #{conf["DONE_TOKEN"]} but open tasks remain — treating as step and continuing."
          klass = :step
        end

        commit_result = commit_turn(turn, model, conf, plan, dir)
        dirty = File.directory?(File.join(dir, ".git")) &&
                !Open3.capture3("git", "-C", dir, "status", "--porcelain")[0].empty?

        case klass
        when :done
          if commit_result.block_reason
            done_gate_fails += 1
            emit "DONE turn was RED at commit gate — treating as repair-needed, not complete (#{done_gate_fails}/#{conf["MAX_DONE_GATE_FAILS"]})."
            if done_gate_fails >= conf["MAX_DONE_GATE_FAILS"].to_i
              emit "ALL_DONE but commit gate stayed RED for #{conf["MAX_DONE_GATE_FAILS"]} turns — STOPPING for human review."
              notify_human "#{File.basename(dir)}: gate RED after ALL_DONE (#{conf["MAX_DONE_GATE_FAILS"]} turns) — needs human review."
              stop_reason = "gate_red"
              break
            end
            sleep_it.call(conf["SHORT_SLEEP"].to_i)
            next
          end
          done_gate_fails = 0
          emit "agent signaled #{conf["DONE_TOKEN"]} — all work complete."
          emit "final model used: #{model}"
          stop_reason = "done"
          break
        when :human
          if dirty && commit_result.committed
            emit "salvaged green work before human-gate stop"
          end
          emit "agent signaled #{conf["HUMAN_TOKEN"]} — needs a human decision; stopping this repo."
          emit "HUMAN NEEDED: #{plan.human_block_brief(task ? task.id : "?", next_task_str)}"
          stop_reason = "human_blocked"
          break
        when :step
          if commit_result.block_reason
            emit "step turn RED at commit gate — next turn will repair. Sleeping #{conf["SHORT_SLEEP"]}s."
            sleep_it.call(conf["SHORT_SLEEP"].to_i)
            next
          end
          emit "step complete (#{conf["STEP_TOKEN"]}). Sleeping #{conf["SHORT_SLEEP"]}s."
          if once
            stop_reason = "once"
            emit "--once: stopping after one step."
            break
          end
          sleep_it.call(conf["SHORT_SLEEP"].to_i)
        when :exhausted
          why = took < 15 ? " — instant-quota, model was already dry" : ""
          emit "model #{model} EXHAUSTED (quota/rate-limit#{why}). Benching #{conf["COOLDOWN"]}s; switching."
          chain.bench!(idx)
          if once
            stop_reason = "once"
            emit "--once: stopping."
            break
          end
          sleep_it.call(conf["SHORT_SLEEP"].to_i)
        when :hard
          benched = chain.strike!(idx)
          emit "model #{model} HARD ERROR (auth/not-found/bad-request). See #{turn_out}"
          emit "benching #{model} after #{conf["MAX_TRANSIENT"]} hard errors — likely a config issue." if benched
          if once
            stop_reason = "once"
            emit "--once: stopping."
            break
          end
          sleep_it.call(conf["SHORT_SLEEP"].to_i)
        when :timeout
          if dirty && commit_result.committed
            emit "turn killed (timeout) but tree was green — salvaged work as a commit; continuing."
            if once
              stop_reason = "once"
              emit "--once: stopping."
              break
            end
            sleep_it.call(conf["SHORT_SLEEP"].to_i)
            next
          end
          benched = chain.strike!(idx)
          emit "model #{model} TIMEOUT (#{result.kill_reason}, no token/error). strike; backing off #{conf["SHORT_SLEEP"]}s."
          emit "benching #{model} after #{conf["MAX_TRANSIENT"]} timeouts." if benched
          if once
            stop_reason = "once"
            emit "--once: stopping."
            break
          end
          sleep_it.call(conf["SHORT_SLEEP"].to_i)
        else # :transient
          benched = chain.strike!(idx)
          emit "model #{model} transient failure. strike; backing off #{conf["SHORT_SLEEP"]}s."
          emit "benching #{model} after #{conf["MAX_TRANSIENT"]} transient failures." if benched
          if once
            stop_reason = "once"
            emit "--once: stopping."
            break
          end
          sleep_it.call(conf["SHORT_SLEEP"].to_i)
        end

        # Milestone-complete detection + bounded review turn (PR_CADENCE=
        # milestone only; bin/ratchet:768-830). Reached ONLY on the common
        # tail -- the `done`/`human` branches `break` and the RED-gate-repair
        # branches `next` above, both skipping this exactly like bash's
        # `break`/`continue` skip the same block.
        if commit_result.committed && (conf["PR_CADENCE"] || "done") == "milestone"
          action = milestone_complete_check(dir, conf, plan, thinking, flat, turn_out, log_dir, sleep_it: sleep_it)
          if action == :review_exceeded
            stop_reason = "review_exceeded"
            break
          end
        end

        # last-turn note for the next turn's prompt
        if commit_result.committed
          changed = Open3.capture3("git", "-C", dir, "diff", "HEAD~1", "--name-only")[0]
                       .lines.first(5).map(&:strip).join(",")
          write_note(log_dir, commit_result.committed, "Last turn changed: #{changed}")
        else
          write_note(log_dir, commit_result.committed, "Last turn: gate RED, left staged.")
        end
      end

      emit "ratchet END after #{turn} turn(s)."
      File.write(File.join(dir, ".ratchet", "stop_reason"), "#{stop_reason}\n")
      state = File.file?(File.join(dir, ".ratchet", "last_task.state")) ? File.read(File.join(dir, ".ratchet", "last_task.state")) : ""
      CLI.metrics_append(dir, "run", "-", "-", last_model, stop_reason, CLI.elapsed_int(run_start),
                         state[/\A[^\t]*/].to_s, run_toks[:in], run_toks[:out], format("%.6f", run_toks[:cost]))
      stop_reason == "gate_red" || stop_reason == "human_blocked" ? 1 : 0
    end

    # write_turn_note (bin/ratchet:179): the gate-status FIRST line is
    # ALWAYS derived from whether this turn committed, so the next turn's
    # prompt never trusts a stale note; REASON is the optional extra line.
    def write_note(log_dir, committed, reason)
      first = committed ? "Verify gate after last turn: GREEN" : "Verify gate after last turn: RED (fix this first)"
      File.write(File.join(log_dir, "last_turn.note"), "#{first}\n#{reason}\n")
    rescue StandardError
      nil
    end

    # bash notify_human: NOTIFY_CMD from ENV only (never the repo conf), MSG as $1.
    def notify_human(msg, notify_cmd: ENV["NOTIFY_CMD"])
      emit "HUMAN NEEDED: #{msg}"
      return if notify_cmd.to_s.empty?

      pid = Process.spawn("sh", "-c", "#{notify_cmd} \"$1\"", "_", msg)
      Process.detach(pid)
    end

    def emit(msg)
      CLI.emit(msg)
    end

    def commit_turn(turn, model, conf, plan, dir)
      CLI.commit_turn(turn, model, conf, plan, dir)
    end

    # Auto-plan PR #0 (bin/ratchet:424-467, PR_CADENCE=milestone only, and
    # only when the tracker is not yet `Plan#ready?`): branch off the default
    # branch, run ONE plan turn, push, open a PR, then block on
    # `wait_for_merge` before the build loop starts. Returns nil to continue
    # into the build loop, or an Integer process exit code (1 or 2) when the
    # caller must stop immediately — mirroring bash's direct `exit 1`/`exit 2`
    # calls in this block, which skip the pid-file write, the turn loop, and
    # the "ratchet END" epilogue entirely.
    def auto_plan_pr0(dir, conf, plan, turn_out, log_path, repo: Repo.new(dir), sys: Sys::Proc.new, sleep_it: Kernel.method(:sleep))
      return nil unless (conf["PR_CADENCE"] || "done") == "milestone"
      return nil if plan.ready?

      emit "auto-plan: tracker not ready, running plan turn on ratchet/plan branch ..."
      default_branch = repo.default_branch
      CLI.die "failed to create ratchet/plan branch" unless repo.checkout_b("ratchet/plan", default_branch)

      Commands.plan_turn(dir, conf, auto: conf["AUTO_PLAN"] == "1", turn_out: turn_out, emit: method(:emit))

      if repo.remote?("origin")
        emit "pushing ratchet/plan ..."
        unless repo.push("-u", "origin", "ratchet/plan")
          notify_human "auto-plan: git push failed (see #{log_path}) — push ratchet/plan manually and merge the PR"
          return 2
        end
      end

      if CLI.on_path?("gh") && repo.remote?("origin")
        repo_name = File.basename(dir)
        diff_text = repo.diff("#{default_branch}..HEAD", conf["TRACKER_FILE"] || "PLAN.md") || ""
        pr_body = diff_text.lines.select { |l| l.start_with?("+") && !l.start_with?("+++") }
                            .map { |l| l.sub(/\A\+/, "") }.join
        emit "opening PR #0 (plan review) ..."
        _out, _err, status = sys.capture("gh", "pr", "create", "--base", default_branch,
                                         "--title", "ratchet plan: #{repo_name}", "--body", "Plan turn output:\n\n#{pr_body}")
        unless status&.success?
          emit "gh pr create failed (see #{log_path})"
          return 1
        end
        emit "PR #0 opened — waiting for merge ..."
      else
        notify_human "auto-plan: merge ratchet/plan PR manually (no gh/origin)"
        return 2
      end

      rc = wait_for_merge("ratchet/plan", dir, conf, repo: repo, sys: sys, sleep_it: sleep_it)
      if rc != 0
        emit "auto-plan: merge wait failed or PR closed — stopping."
        return 1
      end

      emit "auto-plan: PR #0 merged, continuing into build loop ..."
      nil
    end

    # Milestone branch lifecycle (bin/ratchet:469-503, PR_CADENCE=milestone
    # only). Runs ONCE at `run` startup, before the turn loop: if the
    # tracker's current milestone differs from the one recorded in
    # .ratchet/milestone.cur, create a fresh ratchet/m-<slug> branch off the
    # default branch and record name/base_sha/cycle=0/errors=0. This does NOT
    # re-fire mid-loop when a milestone completes (bash places it before the
    # `while true`, not inside it) -- a supervisor's next `run` invocation
    # picks up the following milestone.
    def milestone_branch_lifecycle(dir, conf, plan, repo: Repo.new(dir))
      return unless (conf["PR_CADENCE"] || "done") == "milestone"

      mname = plan.current_milestone&.fetch(:name)
      return if mname.nil? || mname.empty?

      stored_mname, = State.read_milestone_cur(dir)
      return if mname == stored_mname

      prev = stored_mname.nil? ? "none" : stored_mname
      emit "milestone-start | m=#{mname} | prev=#{prev}"

      default_branch = repo.default_branch
      base_sha = repo.rev_parse(default_branch) || repo.rev_parse("HEAD")
      slug = mname.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      branch_name = "ratchet/m-#{slug}"

      CLI.die "failed to create #{branch_name}" unless repo.checkout_b(branch_name, default_branch)

      State.write_milestone_cur(dir, mname, base_sha, 0, 0)
      emit "milestone branch #{branch_name} created at #{base_sha}"
    end

    # Milestone-complete detection + bounded review turn (bin/ratchet:768-830,
    # PR_CADENCE=milestone only). Fires when the just-committed turn moved
    # the tracker's current milestone away from the one recorded in
    # .ratchet/milestone.cur. Returns :review_exceeded when MAX_REVIEW_CYCLES
    # is hit (the caller stops the loop), nil otherwise.
    def milestone_complete_check(dir, conf, plan, thinking, flat, turn_out, log_dir,
                                 repo: Repo.new(dir), sys: Sys::Proc.new, sleep_it: Kernel.method(:sleep))
      stored = State.read_milestone_cur(dir)
      return nil unless stored

      stored_mname, base_sha, cycle_count, review_errors = stored
      return nil if stored_mname.to_s.empty?

      next_mname = plan.current_milestone&.fetch(:name)
      return nil if next_mname == stored_mname

      emit "milestone-complete | m=#{stored_mname}"
      review_status = run_review_turn(base_sha, stored_mname, cycle_count, dir, conf, thinking, flat, turn_out, repo: repo)

      case review_status
      when "pass"
        emit "review-pass | m=#{stored_mname}"
        State.write_milestone_cur(dir, stored_mname, base_sha, cycle_count, 0)
        open_milestone_pr(stored_mname, base_sha, dir, conf, plan, File.join(log_dir, "loop.log"), repo: repo, sys: sys, sleep_it: sleep_it)
        nil
      when "fail"
        emit "review-fail | m=#{stored_mname} | cycle=#{cycle_count + 1}"
        cycle_count += 1
        State.write_milestone_cur(dir, stored_mname, base_sha, cycle_count, 0)
        commit_review_injected_tasks(dir, conf, cycle_count, repo: repo)
        max_cycles = conf["MAX_REVIEW_CYCLES"].to_s.empty? ? 2 : conf["MAX_REVIEW_CYCLES"].to_i
        if cycle_count >= max_cycles
          notify_human "milestone #{stored_mname} exceeded MAX_REVIEW_CYCLES (#{max_cycles}) — review and fix manually"
          emit "MAX_REVIEW_CYCLES exceeded — STOPPING for human review."
          :review_exceeded
        end
      else # "error"
        review_errors += 1
        emit "review-skip | m=#{stored_mname} | reason=reviewer-error (#{review_errors}/2)"
        State.write_milestone_cur(dir, stored_mname, base_sha, cycle_count, review_errors)
        if review_errors >= 2
          emit "  review turn errors twice — proceeding (broken reviewer must not wedge pipeline)."
          State.write_milestone_cur(dir, stored_mname, base_sha, cycle_count, 0)
          open_milestone_pr(stored_mname, base_sha, dir, conf, plan, File.join(log_dir, "loop.log"), repo: repo, sys: sys, sleep_it: sleep_it)
        end
        nil
      end
    end

    # Commit the tracker if the review turn injected fix tasks into it.
    def commit_review_injected_tasks(dir, conf, cycle_count, repo: Repo.new(dir))
      return unless File.directory?(File.join(dir, ".git"))

      repo.add(conf["TRACKER_FILE"] || "PLAN.md")
      return if repo.staged_files.empty?

      repo.commit("review(ratchet): fix tasks from review cycle #{cycle_count}")
      emit "  review-injected tasks committed"
    end

    # run_review_turn BASE_SHA MNAME CYCLE -> "pass"|"fail"|"error"
    # (lib/run-turn.sh:148). Runs ONE read-only review turn with swapped
    # tokens (STEP_TOKEN=REVIEW_PASS, DONE_TOKEN=REVIEW_FAIL) so classify
    # works unmodified: step => pass, done => fail, anything else => error.
    # Never strikes/benches the review model. `thinking` is the JUST-FINISHED
    # build turn's thinking level — bash never calls thinking_for_tier
    # "review" here, it reuses whatever $THINKING main() set for the build
    # turn that triggered this check (bin/ratchet:593 sets it once per turn;
    # run_review_turn never resets it).
    def run_review_turn(base_sha, mname, cycle, dir, conf, thinking, flat, turn_out, repo: Repo.new(dir))
      review_chain = Tier.chain_for("review", conf).to_s
      review_model = review_chain.split(",").reject(&:empty?).first || flat.first
      return "error" if review_model.to_s.empty?

      diff_content = repo.diff("#{base_sha}..HEAD") || "<diff unavailable>"
      template = File.read(File.join(Commands::TEMPLATES_DIR, "REVIEW.prompt.md"))
      prompt = "#{template}\n\n```diff\n#{diff_content}\n```\n\n" \
               "**Milestone**: #{mname} (review cycle #{cycle + 1})\n" \
               "**Tracker**: #{conf["TRACKER_FILE"] || "PLAN.md"}\n"

      cmd = [conf["AGENT_CMD"], "--model", review_model]
      cmd += ["--thinking", thinking] unless thinking.to_s.empty?
      cmd += ["--no-session", "-p", prompt]
      result = Turn.run(cmd: cmd, turn_file: turn_out, chdir: dir,
                        turn_timeout: conf["TURN_TIMEOUT"].to_i,
                        stall_timeout: conf["STALL_TIMEOUT"].to_i,
                        poll_interval: (ENV["POLL_INTERVAL"] || conf["POLL_INTERVAL"] || 3).to_i)
      deadline = !result.kill_reason.nil?
      klass = Classifier.classify(turn_out, step_token: "REVIEW_PASS", done_token: "REVIEW_FAIL",
                                           deadline: deadline, json: false, human_token: conf["HUMAN_TOKEN"])
      case klass
      when :step then "pass"
      when :done then "fail"
      else "error"
      end
    end

    # wait_for_merge BRANCH DIR CONF -> poll the PR until merged/closed/timeout
    # (bin/ratchet:203). Returns 0=merged+ff'd, 1=closed, 2=manual mode
    # (no gh/origin, or gh pr view failed), 3=timeout. Emits the frozen
    # `merge-wait | pr=<branch> | state=<state>` line on state changes only.
    # MERGE_POLL_SECS/MERGE_WAIT_TIMEOUT have no global default in common.sh
    # either (bash resolves them inline with `${VAR:-N}` at this one call
    # site) — mirrored here rather than invented as a Config default.
    def wait_for_merge(branch, dir, conf, repo: Repo.new(dir), sys: Sys::Proc.new, sleep_it: Kernel.method(:sleep))
      unless CLI.on_path?("gh")
        notify_human "merge the PR: gh not found, manual mode"
        return 2
      end
      unless repo.remote?("origin")
        notify_human "merge the PR: no origin remote, manual mode"
        return 2
      end

      default_branch = repo.default_branch
      poll_secs = conf["MERGE_POLL_SECS"].to_s.empty? ? 300 : conf["MERGE_POLL_SECS"].to_i
      timeout = conf["MERGE_WAIT_TIMEOUT"].to_s.empty? ? 259_200 : conf["MERGE_WAIT_TIMEOUT"].to_i
      prev_state = ""
      elapsed = 0
      loop do
        state = pr_state(sys, branch)
        if state.nil?
          notify_human "merge the PR: gh pr view failed"
          return 2
        end
        if state != prev_state && !state.empty?
          emit "merge-wait | pr=#{branch} | state=#{state}"
          prev_state = state
        end
        case state
        when "MERGED"
          return 0 if conf["PARALLEL"] == "1"
          return 1 unless repo.checkout(default_branch)
          return 1 unless repo.pull_ff_only

          return 0
        when "CLOSED"
          notify_human "PR #{branch} was closed without merging"
          return 1
        end

        if elapsed >= timeout
          notify_human "merge timeout (#{timeout}s elapsed) on PR #{branch}"
          emit "merge-wait timeout: #{timeout}s elapsed, stopping cleanly."
          return 3
        end
        sleep_it.call(poll_secs)
        elapsed += poll_secs
      end
    end

    # `gh pr view BRANCH --json state -q .state`, falling back to the plain
    # `--json state` + JSON parse when the `-q` form fails (old gh) — nil when
    # both fail.
    def pr_state(sys, branch)
      out, _err, status = sys.capture("gh", "pr", "view", branch, "--json", "state", "-q", ".state")
      return out.strip if status&.success?

      out, _err, status = sys.capture("gh", "pr", "view", branch, "--json", "state")
      return nil unless status&.success?

      JSON.parse(out)["state"].to_s
    rescue JSON::ParserError
      nil
    end

    # open_milestone_pr NAME BASE_SHA -> push milestone branch, open PR,
    # wait_for_merge (bin/ratchet:261). Returns 0=PR opened+wait_for_merge's
    # result, 1=push or `gh pr create` failed, 2=no gh/origin (manual PR).
    def open_milestone_pr(mname, base_sha, dir, conf, plan, log_path,
                          repo: Repo.new(dir), sys: Sys::Proc.new, sleep_it: Kernel.method(:sleep))
      current_branch = repo.current_branch || "HEAD"
      emit "pushing milestone branch #{current_branch} ..."
      unless repo.push
        emit "git push failed (see #{log_path}) — branch left local."
        return 1
      end
      emit "pushed."
      unless CLI.on_path?("gh") && repo.remote?("origin")
        emit "no gh / no origin — leaving the pushed branch for manual PR."
        return 2
      end

      body = plan.milestone_completed_list(mname).map { |l| "- #{l}" }.join("\n")
      diffstat = repo.diffstat("#{base_sha}..HEAD")
      changed_lines = shortstat_changed_lines(repo.shortstat("#{base_sha}..HEAD"))
      verdict = last_matching_log_line(log_path, /review-pass|review-skip/)

      if changed_lines > conf["PR_SOFT_MAX_LINES"].to_i
        emit "\u26A0 large PR: #{changed_lines} lines (soft limit: #{conf["PR_SOFT_MAX_LINES"]})"
        body = "\u26A0 large PR: #{changed_lines} changed lines\n\n#{body}"
      end
      body = "#{body}\n\n```\n#{diffstat}\n```"
      body = "#{body}\n\n#{verdict}" if verdict

      first_subject = plan.milestone_completed_list(mname).first.to_s.sub(/\A\[x\][[:space:]]*/, "").gsub("**", "")
      emit "opening PR for milestone #{mname} ..."
      _out, _err, status = sys.capture("gh", "pr", "create", "--title", "ratchet #{mname}: #{first_subject}",
                                       "--body-file", "-", stdin_data: body)
      unless status&.success?
        emit "gh pr create failed (see #{log_path})."
        return 1
      end
      emit "PR opened."
      wait_for_merge(current_branch, dir, conf, repo: repo, sys: sys, sleep_it: sleep_it)
    end

    # git diff --shortstat -> total changed lines (insertions + deletions),
    # replacing bash's positional `awk '{print $4+$6}'` with a pattern match
    # that's correct whether one or both counts are present.
    def shortstat_changed_lines(text)
      ins = text[/(\d+) insertions?\(\+\)/, 1].to_i
      del = text[/(\d+) deletions?\(-\)/, 1].to_i
      ins + del
    end

    def last_matching_log_line(log_path, pattern)
      return nil unless File.file?(log_path)

      File.readlines(log_path, chomp: true).reverse_each.find { |l| l =~ pattern }
    end

    # exe/robur beside this repo's lib/ (Commands::TEMPLATES_DIR's sibling
    # pattern) -- the binary `fanout` re-invokes per worktree as `... run`.
    ROBUR_BIN = File.expand_path("../../exe/robur", __dir__)

    # ratchet fanout (lib/commands.sh:cmd_fanout): serially create one git
    # worktree per independent milestone, then fan out parallel `run` loops
    # bounded by FANOUT_MAX, then sweep with fanout_clean. Returns the
    # process exit code (0 on a clean run, 1 on a hard precondition/worktree
    # failure).
    def fanout(dir, conf, repo: Repo.new(dir), sleep_it: Kernel.method(:sleep),
              launch: ->(wt_path) { Process.spawn({ "PARALLEL" => "1" }, ROBUR_BIN, "run", chdir: wt_path, out: File::NULL, err: File::NULL) },
              wait_any: -> { Process.wait },
              wait_pid: lambda do |pid|
                Process.waitpid(pid)
              rescue Errno::ECHILD
                nil
              end)
      dir = File.expand_path(dir)
      CLI.die "not a directory: #{dir}" unless File.directory?(dir)

      unless conf["PARALLEL"] == "1"
        emit "fanout requires PARALLEL=1 (set in .ratchet.conf or via env)"
        return 1
      end
      unless CLI.on_path?("gh")
        emit "fanout requires gh (GitHub CLI) on PATH"
        return 1
      end
      unless repo.remote?("origin")
        emit "fanout requires an 'origin' remote"
        return 1
      end

      emit "ratchet fanout: #{dir}"

      tracker_file = conf["TRACKER_FILE"]
      tracker_file = Commands.detect_tracker_file(dir) if tracker_file.to_s.empty?
      tracker_file = "PLAN.md" if tracker_file.to_s.empty?
      milestones = Plan.new(File.join(dir, tracker_file)).independent_milestones

      if milestones.empty?
        emit "no independent milestones found (tag first open task with (independent))"
        return 0
      end

      emit "  found #{milestones.length} independent milestone(s)"
      default_branch = repo.default_branch

      pairs = []
      milestones.each do |m|
        wt_path = "../ratchet-wt-#{m[:slug]}"
        branch = "ratchet/m-#{m[:slug]}"
        emit "  creating worktree: #{wt_path} (branch #{branch})"

        created = false
        wait_s = 1
        attempt = 1
        while attempt <= 5
          ok, err = repo.worktree_add(wt_path, branch, "origin/#{default_branch}")
          if ok
            created = true
            break
          end
          unless err.to_s.include?("config.lock")
            emit "    worktree add failed:"
            return 1
          end
          emit "    config.lock (attempt #{attempt}/5); waiting #{wait_s}s"
          sleep_it.call(wait_s)
          wait_s *= 2
          attempt += 1
        end
        unless created
          emit "    failed to create worktree after 5 attempts"
          return 1
        end

        pairs << [wt_path, branch]
        State.write_fanout(dir, pairs)
      end

      emit "  all worktrees created"

      max = conf["FANOUT_MAX"].to_s.empty? ? 4 : conf["FANOUT_MAX"].to_i
      active = 0
      pids = []
      reaped = {}

      pairs.each do |wt_path, _branch|
        while active >= max
          pid = wait_any.call
          reaped[pid] = true
          active -= 1
        end
        emit "  launching loop: #{wt_path}"
        pids << launch.call(wt_path)
        active += 1
      end

      emit "  waiting for all loops to complete"
      pids.each { |pid| wait_pid.call(pid) unless reaped[pid] }
      emit "  all loops complete"

      fanout_clean(dir, repo: repo)
      emit "fanout complete"
      0
    end

    # ratchet fanout-clean (lib/commands.sh:cmd_fanout_clean): fail-safe
    # worktree sweep -- NEVER --force removes; a stash for the worktree's
    # branch, an unpushed commit, or a dirty tree (git's own removal refusal)
    # each KEEP the worktree. Returns [removed_count, kept_count].
    def fanout_clean(dir, repo: Repo.new(dir))
      dir = File.expand_path(dir)
      CLI.die "not a directory: #{dir}" unless File.directory?(dir)

      emit "fanout-clean: #{dir}"

      worktrees = repo.worktrees
      if worktrees.empty?
        emit "  no worktrees found"
        return [0, 0]
      end

      removed = 0
      kept = 0
      pairs = State.read_fanout(dir)

      worktrees.drop(1).each do |wt|
        next if wt.branch.to_s.empty?

        stash = repo.stash_list
        if stash.nil?
          emit "  KEEP: #{wt.path} (stash check failed, fail toward KEEP)"
          kept += 1
          next
        end
        if stash.match?(/(?:WIP )?[Oo]n #{Regexp.escape(wt.branch)}:/)
          emit "  KEEP: #{wt.path} (stash entry exists for #{wt.branch})"
          kept += 1
          next
        end

        unpushed = repo.unpushed_commits(wt.path)
        if unpushed.nil?
          emit "  KEEP: #{wt.path} (unpushed check failed, fail toward KEEP)"
          kept += 1
          next
        end
        unless unpushed.strip.empty?
          emit "  KEEP: #{wt.path} (unpushed commits)"
          kept += 1
          next
        end

        if repo.worktree_remove(wt.path)
          emit "  REMOVED: #{wt.path}"
          removed += 1
          emit "    deleted branch #{wt.branch}" if repo.branch_delete_d(wt.branch)
          pairs = pairs.reject { |p, _b| p == wt.path }
          State.write_fanout(dir, pairs)
        else
          emit "  KEEP: #{wt.path} (git worktree remove refused)"
          kept += 1
        end
      end

      emit "fanout-clean: removed=#{removed} kept=#{kept}"
      [removed, kept]
    end
  end
end
