# frozen_string_literal: true

require "open3"
require "robur/config"
require "robur/plan"
require "robur/tier"
require "robur/model_chain"
require "robur/turn"
require "robur/classifier"
require "robur/commit_gate"
require "robur/cli"

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

      emit "=" * 60
      emit "ratchet START"
      emit "  repo      : #{dir}"
      emit "  tracker   : #{conf["TRACKER_FILE"] || "PLAN.md"}"
      emit "  models    : #{flat.join(" ")}  (preference order, fallback chain)"
      emit "  loop log  : #{log_dir}/loop.log"
      emit "=" * 60

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

        # last-turn note for the next turn's prompt
        if commit_result.committed
          changed = Open3.capture3("git", "-C", dir, "diff", "HEAD~1", "--name-only")[0]
                       .lines.first(5).map(&:strip).join(",")
          write_note(log_dir, "Last turn changed: #{changed}")
        else
          write_note(log_dir, "Last turn: gate RED, left staged.")
        end
      end

      emit "ratchet END after #{turn} turn(s)."
      File.write(File.join(dir, ".ratchet", "stop_reason"), "#{stop_reason}\n")
      state = File.file?(File.join(dir, ".ratchet", "last_task.state")) ? File.read(File.join(dir, ".ratchet", "last_task.state")) : ""
      CLI.metrics_append(dir, "run", "-", "-", last_model, stop_reason, CLI.elapsed_int(run_start),
                         state[/\A[^\t]*/].to_s, run_toks[:in], run_toks[:out], format("%.6f", run_toks[:cost]))
      stop_reason == "gate_red" || stop_reason == "human_blocked" ? 1 : 0
    end

    def write_note(log_dir, text)
      File.write(File.join(log_dir, "last_turn.note"), "#{text}\n")
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
  end
end
