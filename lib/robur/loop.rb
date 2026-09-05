# frozen_string_literal: true

require "json"
require "open3"
require "robur/config"
require "robur/paths"
require "robur/plan"
require "robur/tier"
require "robur/prompt"
require "robur/model_health"
require "robur/progress_guard"
require "robur/render"
require "robur/observability"
require "robur/turn"
require "robur/classifier"
require "robur/commit_gate"
require "robur/cli"
require "robur/repo"
require "robur/sys"
require "robur/state"
require "robur/commands"
require "robur/lifecycle"

module Robur
  # The unattended run loop: one turn per cycle until the agent is done, the
  # models are all benched, or a human is needed.
  # Shares CLI's emit/commit_turn/metrics helpers (same loop.log surface);
  # sleep is injectable so the all-benched ladder is testable.
  module Loop
    BACKOFF_LADDER = [900, 3600, 14400].freeze

    module_function

    # Full `robur run`. Returns the process exit code (0 on a clean stop).
    def run(dir, once: false, sleep_it: Kernel.method(:sleep))
      dir = File.expand_path(dir)
      conf = Robur::Config.load(dir, {}).values
      log_dir = File.join(Paths.logs_dir, CLI.project_slug(dir))
      FileUtils.mkdir_p(log_dir)
      Paths.ensure_state_dir!(dir)
      File.write(Paths.state_file(dir, "last-log"), "#{log_dir}\n")
      # A run is "running" from startup, so a SIGKILLed loop never leaves the
      # PREVIOUS run's verdict standing for the external supervisor to read.
      State.write_stop_reason(dir, "running")
      CLI.instance_variable_set(:@quiet, conf["QUIET"] == "1")
      CLI.instance_variable_set(:@loop_log, File.join(log_dir, "loop.log"))

      plan = Plan.new(File.join(dir, conf["TRACKER_FILE"] || "PLAN.md"))
      flat = conf["MODELS"].to_s.split(",").reject(&:empty?)
      CLI.die "no models configured (-m chain, MODELS in #{Paths::REPO_CONF}, or global conf)." if flat.empty?

      turn_out = File.join(log_dir, "last_turn.out")
      run_start = CLI.mono
      run_toks = { in: 0, out: 0, cost: 0.0 }
      turn = 0
      last_model = "none"
      done_gate_fails = 0
      all_benched_count = 0
      stop_reason = "crashed"
      # Audit fix #1 (2026-09-03): ONE health registry keyed by MODEL id —
      # the old chain-keyed state gave a model in both a tier chain and flat
      # MODELS two independent strike counters (the production infinite-spin).
      health = ModelHealth.new(conf, max_transient: conf["MAX_TRANSIENT"].to_i)
      # Audit fix #2: no-progress detector over tracker mtime + commits.
      guard = ProgressGuard.new(File.join(dir, conf["TRACKER_FILE"] || "PLAN.md"))
      obs = Observability.new(log_dir)

      emit = ->(m) { CLI.emit(m) }

      session_id = conf["SESSION_NAME"].to_s.empty? ? "robur-#{CLI.project_slug(dir)}" : "robur-#{conf["SESSION_NAME"]}"
      resume = conf["RESUME_SESSION"] == "1" ? "yes" : "no"
      thinking_banner = conf["THINKING"].to_s.empty? ? "inherit" : conf["THINKING"]

      obs.emit(:run_start, repo: dir, session: "#{session_id} (resume=#{resume})",
               tracker: conf["TRACKER_FILE"] || "PLAN.md", models: flat,
               turn_timeout: conf["TURN_TIMEOUT"], cooldown: conf["COOLDOWN"],
               both_wait: conf["BOTH_WAIT"], step_token: conf["STEP_TOKEN"],
               done_token: conf["DONE_TOKEN"], agent_cmd: conf["AGENT_CMD"],
               thinking: thinking_banner, verify_cmd: conf["VERIFY_CMD"],
               commit_each_turn: conf["COMMIT_EACH_TURN"], push_on_done: conf["PUSH_ON_DONE"],
               open_pr: conf["OPEN_PR"], log_dir: log_dir)

      # Life is installed BEFORE auto_plan_pr0 so its wait_for_merge poll
      # (poll_secs default 300, timeout 3 days) is interruptible too (T1.4).
      life = Robur::Lifecycle.new(dir).install!
      # Clearing first means a stop file left over from a previous session
      # cannot instantly kill a fresh run.
      Robur::State.clear_stop(dir)

      exit_code = auto_plan_pr0(dir, conf, plan, turn_out, File.join(log_dir, "loop.log"), sleep_it: sleep_it, life: life)
      return exit_code if exit_code

      milestone_branch_lifecycle(dir, conf, plan)

      # flock loop.pid so two loops cannot share one tree (the kernel releases
      # the lock on process death, so it cannot go stale like a PID file).
      pid_path = File.join(log_dir, "loop.pid")
      unless life.acquire_lock!(pid_path)
        holder = File.read(pid_path).to_i
        CLI.die "another loop (pid #{holder}) holds the lock on #{pid_path}; refusing to run two loops on one tree."
      end

      report_unclean_start(dir, obs)

      begin
        loop do
          if life.stop_requested?
            emit "stop requested — finishing cleanly, no new turn will start."
            obs.emit(:stop_requested, source: "stop file", level: life.level)
            stop_reason = "stopped"
            break
          end
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

          # Tier routing (audit fix #1): pick through the ONE health registry,
          # so bench/strike state follows the MODEL across tier and flat chains.
          tag = plan.next_task(:in_progress)&.tags&.first || plan.next_task(:open)&.tags&.first
          tier = Tier.from_tag(tag, cheap: conf["CHEAP_MODE"] == "1")
          tier_chain = Tier.chain_for(tier, conf).to_s
          tier_chain = flat.join(",") if tier_chain.empty?
          models = tier_chain.split(",").reject(&:empty?)
          model = health.pick(models)
          if model.nil? && tier_chain != flat.join(",")
            emit "tier (#{tier}) chain exhausted — falling back to MODELS for this turn."
            model = health.pick(flat)
          end
          if model.nil?
            # ALL models benched: ladder backoff, reset, retry. reset_all keeps
            # attempts/wins, so hard-disabled models STAY disabled — the point.
            all_benched_count += 1
            backoff = BACKOFF_LADDER[all_benched_count - 1] || BACKOFF_LADDER.last
            emit "ALL models benched (exhausted), attempt #{all_benched_count}. Sleeping #{backoff}s, then reset + retry."
            life.sleep(backoff, sleep_it: sleep_it)
            health.reset_all
            next
          end

          last_model = model
          thinking = Tier.thinking_for(tier, conf, model: model)
          obs.emit_event(:model_selected, model: model, tier: tier, chain: tier_chain,
                                             reason: "pos #{models.index(model) || flat.index(model)} of #{tier_chain}")

          task = plan.next_task(:in_progress) || plan.next_task(:open)
          next_task_str = task ? "#{task.id} (#{task.tags.join(", ")}) #{task.text}" : ""
          done_n = plan.count(:done)
          open_n = plan.count(:open) + plan.count(:in_progress)
          emit "tasks: #{done_n} done / #{done_n + open_n} total | next: #{next_task_str.slice(0, 60)}"

          # Live PM header — terminal only, never into loop.log (status_report
          # greps that file; a status block in it would poison the parser).
          unless CLI.quiet?
            ms = plan.current_milestone || {}
            $stdout.print Render.status_block(done_n, done_n + open_n,
                                              ms[:name].to_s, ms[:done].to_i, ms[:total].to_i,
                                              turn, tier, model,
                                              task ? task.id : "?", (task ? task.text : next_task_str).to_s.slice(0, 70))
            $stdout.flush
          end

          obs.emit(:turn_start, turn: turn, model: model, tier: tier, thinking: thinking, task: next_task_str)

          Paths.loop_env_vars.each { |k| ENV[k] = "1" }
          turn_start = CLI.mono
          cmd = [conf["AGENT_CMD"], "--model", model] + Turn.mode_args(conf["AGENT_CMD"], kind: :step)
          cmd += ["--thinking", thinking] unless thinking.to_s.empty?
          # P0 fix (audit 2026-09-03): build the REAL per-turn prompt (base +
          # task block + last-turn note + RED verify tail) — the loop used to
          # send the literal string "turn". PROMPT_OVERRIDE (-p) still wins.
          prompt = conf["PROMPT_OVERRIDE"].to_s.empty? ? Prompt.for_turn(conf: conf, plan: plan, log_dir: log_dir) : conf["PROMPT_OVERRIDE"]
          # Persist what the agent is being asked this turn — watch links it,
          # and post-hoc debugging of a bad turn needs the exact prompt.
          File.write(File.join(log_dir, "last_prompt.txt"), prompt)
          cmd += ["--no-session", "-p", prompt]
          result = Turn.run(cmd: cmd, turn_file: turn_out, chdir: dir,
                            turn_timeout: conf["TURN_TIMEOUT"].to_i,
                            stall_timeout: conf["STALL_TIMEOUT"].to_i,
                            poll_interval: (ENV["POLL_INTERVAL"] || conf["POLL_INTERVAL"] || 3).to_i,
                            early_tokens: [conf["STEP_TOKEN"], conf["DONE_TOKEN"]],
                            stop_check: -> { life.level })
          if result.kill_reason == "stop-requested"
            emit "stop requested mid-turn — salvaging green work and stopping."
            obs.emit(:stop_requested, source: "mid-turn watchdog", level: life.level)
            commit_turn(turn, model, conf, plan, dir)
            stop_reason = "stopped"
            break
          end
          status = result.kill_reason ? 128 + (result.status.termsig || 0) : result.status.exitstatus
          deadline = !result.kill_reason.nil? && result.kill_reason != "token-seen"
          klass = Classifier.classify(turn_out, step_token: conf["STEP_TOKEN"], done_token: conf["DONE_TOKEN"],
                                               deadline: deadline, json: Turn.pi_json?(conf["AGENT_CMD"]), human_token: conf["HUMAN_TOKEN"])
          took = CLI.elapsed_int(turn_start)
          obs.emit(:turn_end, turn: turn, class: klass, took: took, exitcode: status, task: next_task_str.slice(0, 20))

          # tin is cache-inclusive (audit fix #4): input + cache_read +
          # cache_write. Counting only fresh input under-reported the real
          # spend by 50-100x once prompt caching was in play.
          detail = Observability.turn_usage_detail(turn_out)
          tin = detail[:input] + detail[:cache_read] + detail[:cache_write]
          tout = detail[:output]
          cost = format("%.6f", detail[:cost])
          CLI.metrics_append(dir, "turn", turn, tier, model, klass, took, task ? task.id : "?", tin, tout, cost,
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
          File.write(Paths.state_file(dir, "last_task.state"), "#{task ? task.id : "?"}\t#{klass}\n")

          if !ENV.fetch("SUMMARY_LINES", "4").to_i.zero? && File.exist?(turn_out) && !File.zero?(turn_out)
            emit "--- summary ---"
            lines = File.read(turn_out).lines.reject { |l| l =~ /^[[:space:]]*$/ }
            lines.last(ENV.fetch("SUMMARY_LINES", "4").to_i).each { |l| CLI.flow(l) }
            emit "---"
          end

          # sanity-gate BEFORE the case: done-with-open-tasks is mid-work.
          # Setting the status inside a `done` arm would never re-dispatch, and
          # the loop would exit with open tasks — downgrade here instead.
          if klass == :done && (plan.open? || plan.in_progress?)
            emit "agent printed #{conf["DONE_TOKEN"]} but open tasks remain — treating as step and continuing."
            klass = :step
          end

          commit_result = commit_turn(turn, model, conf, plan, dir)
          obs.emit_event(:gate_result,
                         status: commit_result.committed ? "green" : commit_result.block_reason ? "red" : "skipped",
                         reason: commit_result.block_reason || (commit_result.committed ? "committed" : "no-op"))
          health.record!(model, klass)

          # No-progress detector (audit fix #2): every path records here, before
          # the classification arms below break/next.
          note_written = false
          case guard.record(committed: commit_result.committed)
          when :bench
            health.bench!(model)
            obs.emit_event(:model_benched, model: model, seconds: conf["COOLDOWN"].to_i,
                                            reason: "progress stalled #{guard.stalls} turns")
            emit "no progress for #{guard.stalls} turns — benching #{model}; switching model."
          when :inject_context
            obs.emit_event(:progress_stall, stalls: guard.stalls, action: "context injected into next prompt")
            stall_msg = "No progress in #{guard.stalls} turns: the tracker did not change and nothing committed. " \
                        "Re-read the current task in #{conf["TRACKER_FILE"] || "PLAN.md"}, change your approach, " \
                        "and write the changes to files. If the task is truly blocked, print #{conf["HUMAN_TOKEN"]} " \
                        "instead of repeating the same step."
            write_note(log_dir, commit_result.committed, stall_msg)
            note_written = true
            emit "no progress for #{guard.stalls} turns — context injected into the next turn's prompt."
          when :block_task
            obs.emit_event(:task_blocked, task: task ? task.id : "?", stalls: guard.stalls)
            block_current_task(dir, conf, task, guard.stalls)
            emit "task #{task ? task.id : "?"} BLOCKED after #{guard.stalls} no-progress turns — advancing to the next task."
          when :stop
            obs.emit_event(:progress_stall, stalls: guard.stalls, action: "loop stopped")
            emit "no progress for #{guard.stalls} turns — STOPPING (progress_stalled)."
            notify_human "#{File.basename(dir)}: no progress for #{guard.stalls} turns on task #{task ? task.id : "?"} — loop stopped for human review."
            stop_reason = "progress_stalled"
            break
          end

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
              life.sleep(conf["SHORT_SLEEP"].to_i, sleep_it: sleep_it)
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
              life.sleep(conf["SHORT_SLEEP"].to_i, sleep_it: sleep_it)
              next
            end
            emit "step complete (#{conf["STEP_TOKEN"]}). Sleeping #{conf["SHORT_SLEEP"]}s."
            if once
              stop_reason = "once"
              emit "--once: stopping after one step."
              break
            end
            life.sleep(conf["SHORT_SLEEP"].to_i, sleep_it: sleep_it)
          when :exhausted
            why = took < 15 ? " — instant-quota, model was already dry" : ""
            emit "model #{model} EXHAUSTED (quota/rate-limit#{why}). Benching #{conf["COOLDOWN"]}s; switching."
            obs.emit_event(:model_benched, model: model, seconds: conf["COOLDOWN"].to_i, reason: "exhausted")
            health.bench!(model)
            if once
              stop_reason = "once"
              emit "--once: stopping."
              break
            end
            life.sleep(conf["SHORT_SLEEP"].to_i, sleep_it: sleep_it)
          when :hard
            benched = health.strike!(model)
            emit "model #{model} HARD ERROR (auth/not-found/bad-request). See #{turn_out}"
            emit "benching #{model} after #{conf["MAX_TRANSIENT"]} hard errors — likely a config issue." if benched
            if once
              stop_reason = "once"
              emit "--once: stopping."
              break
            end
            life.sleep(conf["SHORT_SLEEP"].to_i, sleep_it: sleep_it)
          when :timeout
            if dirty && commit_result.committed
              emit "turn killed (timeout) but tree was green — salvaged work as a commit; continuing."
              if once
                stop_reason = "once"
                emit "--once: stopping."
                break
              end
              life.sleep(conf["SHORT_SLEEP"].to_i, sleep_it: sleep_it)
              next
            end
            benched = health.strike!(model)
            emit "model #{model} TIMEOUT (#{result.kill_reason}, no token/error). strike; backing off #{conf["SHORT_SLEEP"]}s."
            emit "benching #{model} after #{conf["MAX_TRANSIENT"]} timeouts." if benched
            if once
              stop_reason = "once"
              emit "--once: stopping."
              break
            end
            life.sleep(conf["SHORT_SLEEP"].to_i, sleep_it: sleep_it)
          when :empty
            # Exit-0-no-output (audit fix #3): NOT a strike — bench immediately.
            # 1,574 production turns like this hid inside :transient, retried forever.
            health.bench!(model)
            obs.emit_event(:model_benched, model: model, seconds: conf["COOLDOWN"].to_i, reason: "empty output")
            emit "model #{model} EMPTY OUTPUT (exit 0, nothing said) — benching #{conf["COOLDOWN"]}s, no strike."
            if once
              stop_reason = "once"
              emit "--once: stopping."
              break
            end
            life.sleep(conf["SHORT_SLEEP"].to_i, sleep_it: sleep_it)
          else # :transient
            benched = health.strike!(model)
            emit "model #{model} transient failure. strike; backing off #{conf["SHORT_SLEEP"]}s."
            emit "benching #{model} after #{conf["MAX_TRANSIENT"]} transient failures." if benched
            if once
              stop_reason = "once"
              emit "--once: stopping."
              break
            end
            life.sleep(conf["SHORT_SLEEP"].to_i, sleep_it: sleep_it)
          end

          # Milestone-complete detection + bounded review turn
          # (PR_CADENCE=milestone only). Reached ONLY on the common tail -- the
          # `done`/`human` branches `break` and the RED-gate-repair branches
          # `next` above, so neither reaches this block.
          if commit_result.committed && (conf["PR_CADENCE"] || "done") == "milestone"
            action = milestone_complete_check(dir, conf, plan, thinking, flat, turn_out, log_dir, sleep_it: sleep_it, life: life)
            if action == :review_exceeded
              stop_reason = "review_exceeded"
              break
            end
          end

          # last-turn note for the next turn's prompt (skipped when the
          # progress guard already wrote the stall context this turn)
          unless note_written
            if commit_result.committed
              changed = Open3.capture3("git", "-C", dir, "diff", "HEAD~1", "--name-only")[0]
                           .lines.first(5).map(&:strip).join(",")
              write_note(log_dir, commit_result.committed, "Last turn changed: #{changed}")
            else
              write_note(log_dir, commit_result.committed, "Last turn: gate RED, left staged.")
            end
          end
        end
      ensure
        # Epilogue on EVERY exit path — this is the only thing the external
        # supervisor reads; before the ensure it was skipped whenever the
        # turn loop raised instead of falling out normally.
        obs.emit(:stopped, reason: stop_reason, turns: turn)
        obs.emit(:run_end, turns: turn)
        File.write(Paths.state_file(dir, "stop_reason"), "#{stop_reason}\n")
        state = File.file?(Paths.state_file(dir, "last_task.state")) ? File.read(Paths.state_file(dir, "last_task.state")) : ""
        CLI.metrics_append(dir, "run", "-", "-", last_model, stop_reason, CLI.elapsed_int(run_start),
                           state[/\A[^\t]*/].to_s, run_toks[:in], run_toks[:out], format("%.6f", run_toks[:cost]))
      end

      stop_reason == "gate_red" || stop_reason == "human_blocked" ? 1 : 0
    end

    # Startup residue check: a turn SIGKILLed before its commit gate leaves
    # files staged in the index. Report and LEAVE them — the next turn's
    # commit gate runs VERIFY_CMD over exactly this staging area, which is
    # the right owner of the keep/discard decision. Read-only.
    def report_unclean_start(dir, obs)
      staged, = Open3.capture3("git", "-C", dir, "diff", "--cached", "--name-only")
      return if staged.strip.empty?

      n = staged.lines.map(&:strip).reject(&:empty?).size
      obs.emit(:recovered, staged_files: n)
      emit "unclean start: recovered after a previous exit with #{n} staged file(s) — left staged for the next commit gate."
    end

    # Progress-guard :block_task — mark the tracker's current task BLOCKED
    # and commit, so the loop advances past it instead of spinning (audit
    # fix #2; the frozen grammar has no BLOCKED status, so the checkbox flips
    # to [x] — the only advance mechanism — and "BLOCKED" rides in the task
    # text, preserved for the human). ponytail: skips silently when the
    # agent rewrote the tracker this turn and the task's lineno no longer
    # matches — the guard's :stop at stop_at still bounds that case.
    def block_current_task(dir, conf, task, stalls, repo: Repo.new(dir))
      return if task.nil?

      tracker = conf["TRACKER_FILE"] || "PLAN.md"
      path = File.join(dir, tracker)
      return unless File.file?(path)

      lines = File.readlines(path)
      ln = lines[task.lineno - 1]
      return unless ln&.include?(task.id) && (m = ln.match(/\A(\s*-\s*\[)[^\]]+(\])/))

      lines[task.lineno - 1] = "#{m[1]}x#{m[2]}#{m.post_match.chomp} — BLOCKED by progress guard (#{stalls} no-progress turns)\n"
      File.write(path, lines.join)
      return unless File.directory?(File.join(dir, ".git"))

      repo.add(tracker)
      repo.commit("loop(#{Paths::COMMIT_SCOPE}): task #{task.id} BLOCKED \u2014 no progress in #{stalls} turns") unless repo.staged_files.empty?
    end

    # The gate-status FIRST line of last_turn.note is ALWAYS derived from whether this turn committed, so the next turn's
    # prompt never trusts a stale note; REASON is the optional extra line.
    def write_note(log_dir, committed, reason)
      first = committed ? "Verify gate after last turn: GREEN" : "Verify gate after last turn: RED (fix this first)"
      File.write(File.join(log_dir, "last_turn.note"), "#{first}\n#{reason}\n")
    rescue StandardError
      nil
    end

    # NOTIFY_CMD comes from ENV only, never the repo conf: an agent can write
    # the repo conf, and this runs a shell command.
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

    # Auto-plan PR #0 (PR_CADENCE=milestone only, and only when the tracker
    # is not yet `Plan#ready?`): branch off the default branch, run ONE plan
    # turn, push, open a PR, then block on `wait_for_merge` before the build
    # loop starts. Returns nil to continue into the build loop, or an Integer
    # process exit code (1 or 2) when the caller must stop immediately — a
    # stop here skips the pid-file write, the turn loop, and the run-end
    # epilogue entirely.
    def auto_plan_pr0(dir, conf, plan, turn_out, log_path, repo: Repo.new(dir), sys: Sys::Proc.new, sleep_it: Kernel.method(:sleep), life: nil)
      return nil unless (conf["PR_CADENCE"] || "done") == "milestone"
      return nil if plan.ready?

      emit "auto-plan: tracker not ready, running plan turn on #{Paths.plan_branch} branch ..."
      default_branch = repo.default_branch
      CLI.die "failed to create #{Paths.plan_branch} branch" unless repo.checkout_b(Paths.plan_branch, default_branch)

      Commands.plan_turn(dir, conf, auto: conf["AUTO_PLAN"] == "1", turn_out: turn_out, emit: method(:emit))

      if repo.remote?("origin")
        emit "pushing #{Paths.plan_branch} ..."
        unless repo.push("-u", "origin", Paths.plan_branch)
          notify_human "auto-plan: git push failed (see #{log_path}) — push #{Paths.plan_branch} manually and merge the PR"
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
                                         "--title", "#{Paths::BRANCH_NS} plan: #{repo_name}", "--body", "Plan turn output:\n\n#{pr_body}")
        unless status&.success?
          emit "gh pr create failed (see #{log_path})"
          return 1
        end
        emit "PR #0 opened — waiting for merge ..."
      else
        notify_human "auto-plan: merge #{Paths.plan_branch} PR manually (no gh/origin)"
        return 2
      end

      rc = wait_for_merge(Paths.plan_branch, dir, conf, repo: repo, sys: sys, sleep_it: sleep_it, life: life)
      if rc != 0
        emit "auto-plan: merge wait failed or PR closed — stopping."
        return 1
      end

      emit "auto-plan: PR #0 merged, continuing into build loop ..."
      nil
    end

    # Milestone branch lifecycle (PR_CADENCE=milestone only). Runs ONCE at
    # `run` startup, before the turn loop: if the tracker's current milestone
    # differs from the one recorded in the state dir's milestone.cur, create a
    # fresh milestone branch off the default branch and record
    # name/base_sha/cycle=0/errors=0. This deliberately does NOT re-fire
    # mid-loop when a milestone completes -- a supervisor's next `run`
    # invocation picks up the following milestone.
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
      branch_name = Paths.milestone_branch(slug)

      CLI.die "failed to create #{branch_name}" unless repo.checkout_b(branch_name, default_branch)

      State.write_milestone_cur(dir, mname, base_sha, 0, 0)
      emit "milestone branch #{branch_name} created at #{base_sha}"
    end

    # Milestone-complete detection + bounded review turn
    # (PR_CADENCE=milestone only). Fires when the just-committed turn moved
    # the tracker's current milestone away from the one recorded in the state
    # dir's milestone.cur. Returns :review_exceeded when MAX_REVIEW_CYCLES
    # is hit (the caller stops the loop), nil otherwise.
    def milestone_complete_check(dir, conf, plan, thinking, flat, turn_out, log_dir,
                                 repo: Repo.new(dir), sys: Sys::Proc.new, sleep_it: Kernel.method(:sleep), life: nil)
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
        open_milestone_pr(stored_mname, base_sha, dir, conf, plan, File.join(log_dir, "loop.log"), repo: repo, sys: sys, sleep_it: sleep_it, life: life)
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
          open_milestone_pr(stored_mname, base_sha, dir, conf, plan, File.join(log_dir, "loop.log"), repo: repo, sys: sys, sleep_it: sleep_it, life: life)
        end
        nil
      end
    end

    # Commit the tracker if the review turn injected fix tasks into it.
    def commit_review_injected_tasks(dir, conf, cycle_count, repo: Repo.new(dir))
      return unless File.directory?(File.join(dir, ".git"))

      repo.add(conf["TRACKER_FILE"] || "PLAN.md")
      return if repo.staged_files.empty?

      repo.commit("review(#{Paths::COMMIT_SCOPE}): fix tasks from review cycle #{cycle_count}")
      emit "  review-injected tasks committed"
    end

    # BASE_SHA MNAME CYCLE -> "pass"|"fail"|"error". Runs ONE read-only
    # review turn with swapped tokens (STEP_TOKEN=REVIEW_PASS,
    # DONE_TOKEN=REVIEW_FAIL) so classify works unmodified: step => pass,
    # done => fail, anything else => error. Never strikes/benches the review
    # model. `thinking` is deliberately the JUST-FINISHED build turn's level,
    # not a review-tier lookup: the review reads the same diff the build turn
    # produced, so it gets the same reasoning budget.
    def run_review_turn(base_sha, mname, cycle, dir, conf, thinking, flat, turn_out, repo: Repo.new(dir))
      review_chain = Tier.chain_for("review", conf).to_s
      review_model = review_chain.split(",").reject(&:empty?).first || flat.first
      return "error" if review_model.to_s.empty?

      diff_content = repo.diff("#{base_sha}..HEAD") || "<diff unavailable>"
      template = File.read(File.join(Commands::TEMPLATES_DIR, "REVIEW.prompt.md"))
      prompt = "#{template}\n\n```diff\n#{diff_content}\n```\n\n" \
               "**Milestone**: #{mname} (review cycle #{cycle + 1})\n" \
               "**Tracker**: #{conf["TRACKER_FILE"] || "PLAN.md"}\n"

      # Every spawned turn gets the loop marker — review turns included.
      Paths.loop_env_vars.each { |k| ENV[k] = "1" }

      cmd = [conf["AGENT_CMD"], "--model", review_model] + Turn.mode_args(conf["AGENT_CMD"], kind: :review)
      cmd += ["--thinking", thinking] unless thinking.to_s.empty?
      cmd += ["--no-session", "-p", prompt]
      result = Turn.run(cmd: cmd, turn_file: turn_out, chdir: dir,
                        turn_timeout: conf["TURN_TIMEOUT"].to_i,
                        stall_timeout: conf["STALL_TIMEOUT"].to_i,
                        poll_interval: (ENV["POLL_INTERVAL"] || conf["POLL_INTERVAL"] || 3).to_i,
                        early_tokens: ["REVIEW_PASS", "REVIEW_FAIL"])
      deadline = !result.kill_reason.nil? && result.kill_reason != "token-seen"
      klass = Classifier.classify(turn_out, step_token: "REVIEW_PASS", done_token: "REVIEW_FAIL",
                                           deadline: deadline, json: Turn.pi_json?(conf["AGENT_CMD"]), human_token: conf["HUMAN_TOKEN"])
      case klass
      when :step then "pass"
      when :done then "fail"
      else "error"
      end
    end

    # BRANCH DIR CONF -> poll the PR until merged/closed/timeout. Returns
    # 0=merged+ff'd, 1=closed, 2=manual mode (no gh/origin, or gh pr view
    # failed), 3=timeout, 4=stop requested (checked at the top of every poll,
    # so a stop never waits out the full poll interval). Callers treat any
    # nonzero as "did not merge". Emits the frozen
    # `merge-wait | pr=<branch> | state=<state>` line on state changes only.
    # MERGE_POLL_SECS/MERGE_WAIT_TIMEOUT are resolved inline here rather than
    # as Config defaults: this is their only call site, and a global default
    # would imply they apply to turns that never poll a PR.
    def wait_for_merge(branch, dir, conf, repo: Repo.new(dir), sys: Sys::Proc.new, sleep_it: Kernel.method(:sleep), life: nil)
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
        return 4 if life&.stop_requested?

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
        life ? life.sleep(poll_secs, sleep_it: sleep_it) : sleep_it.call(poll_secs)
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

    # NAME BASE_SHA -> push milestone branch, open PR, wait_for_merge. Returns 0=PR opened+wait_for_merge's
    # result, 1=push or `gh pr create` failed, 2=no gh/origin (manual PR).
    def open_milestone_pr(mname, base_sha, dir, conf, plan, log_path,
                          repo: Repo.new(dir), sys: Sys::Proc.new, sleep_it: Kernel.method(:sleep), life: nil)
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
      _out, _err, status = sys.capture("gh", "pr", "create", "--title", "#{Paths::BRANCH_NS} #{mname}: #{first_subject}",
                                       "--body-file", "-", stdin_data: body)
      unless status&.success?
        emit "gh pr create failed (see #{log_path})."
        return 1
      end
      emit "PR opened."
      wait_for_merge(current_branch, dir, conf, repo: repo, sys: sys, sleep_it: sleep_it, life: life)
    end

    # git diff --shortstat -> total changed lines (insertions + deletions).
    # Matched by pattern, not by field position, so it stays correct whether
    # one or both counts are present.
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

    # fanout: serially create one git worktree per independent milestone, then fan out parallel `run` loops
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
        emit "fanout requires PARALLEL=1 (set in #{Paths::REPO_CONF} or via env)"
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

      emit "robur fanout: #{dir}"

      life = Robur::Lifecycle.new(dir).install!

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
        wt_path = Paths.worktree_path(m[:slug])
        branch = Paths.milestone_branch(m[:slug])
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
      notified = false
      remaining = pids.reject { |pid| reaped[pid] }
      until remaining.empty?
        if life.stop_requested? && !notified
          mode = life.abort? ? "now" : "drain"
          pairs.each { |wt_path, _b| Robur::State.write_stop(wt_path, mode) }
          emit "  stop requested — wrote #{mode} to #{pairs.size} worktree(s)"
          notified = true
        end
        remaining.reject! do |pid|
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          true
        end
        life.sleep(1, sleep_it: sleep_it) unless remaining.empty?
      end
      emit "  all loops complete"

      fanout_clean(dir, repo: repo)
      emit "fanout complete"
      0
    end

    # fanout-clean: fail-safe
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
