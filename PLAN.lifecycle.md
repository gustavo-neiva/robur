<!-- class: MACHINE -->
# PLAN.lifecycle.md — robur: graceful stop, single-instance, self-heal

> Tracker grammar: `[ ]` open → `[IN PROGRESS]` → `[x]` done. Tags
> `(trivial|normal|hard)` route the model tier; `(serial)` forbids parallel
> siblings.

This tracker is selected by `TRACKER_FILE=PLAN.lifecycle.md` in `.robur.conf`.
There is no `--tracker` CLI flag; the conf is the only way to point the loop at
it. The repo's own `PLAN.md` (the bash-to-Ruby migration, all tasks complete)
must not be touched by any task here.

## How to do ONE task here (read this first, every turn)

You have no memory of any previous turn. Everything you need is in your task
block. The mechanical recipe, every time:

1. Read the files named in `touches:`. Do not read anything else unless the
   task says to.
2. Find the anchor. Tasks give you an **exact string to search for**, not a
   line number — line numbers move as the file is edited, the string does not.
3. Make ONLY the change in `do:`. Do not rename things, do not reformat, do not
   "improve" nearby code, do not add comments to code you did not write.
4. Add the test case described in `accept:` to the test file named in
   `touches:`. One test per Given/When/Then pair. Use plain Minitest
   (`def test_x ... assert ... end`) — the repo has no fixtures or helpers
   beyond `test/test_helper.rb`.
5. Run `verify:`. It must exit 0. If it fails, fix it before finishing.
6. Change this task's `- [ ]` to `- [x]` in PLAN.lifecycle.md.
7. Print `STEP_COMPLETE`.

Repo rules that apply to every task, no exceptions:

- **Ruby standard library only.** No gems, no Bundler, no Gemfile, no Sorbet,
  no type signatures.
- **New file under `lib/robur/`?** You must add its `require` to BOTH
  `lib/robur/cli.rb` and `exe/robur`. `exe/robur` resolves `lib/` beside itself
  and will crash at runtime otherwise. This is the single most common mistake
  in this repo.
- **Never add a key to `Config::ALLOWLIST`.** It is a frozen contract and
  `doctor` errors on unknown keys. Operational knobs go in `ENV` — the existing
  examples are `POLL_INTERVAL`, `SUMMARY_LINES`, `ROBUR_RUNAWAY_MESSAGES`.
- **Never hardcode an on-disk filename.** Every one lives in `Robur::Paths`.
- **Never put a `#` character in a `.robur.conf` value.** The parser truncates
  at the first `#`.

## Why this plan exists

`grep -rn trap lib/ exe/` returns nothing. `robur run` is a long-lived process
that spawns an agent child per turn, yet it handles no signals. Four
consequences, all present in the code today:

1. **Orphaned agents.** `Loop.run` spawns the agent through `Turn.run` →
   `Sys::Proc#spawn`. SIGTERM/Ctrl-C kills the Ruby parent instantly; the agent
   child survives, keeps editing the repo and keeps spending tokens. A
   "restart" is therefore a hard kill that leaves a live agent writing the tree
   while a second loop starts a second agent on it.
2. **A lying supervisor contract.** The epilogue in `Loop.run` — the
   `stop_reason` write, `obs.emit(:run_end, ...)` and the
   `CLI.metrics_append(dir, "run", ...)` row — is the ONLY thing
   `atlas/bin/money-loop.sh` reads to classify a cycle. On a signal none of it
   runs. Observed live on 2026-09-04: `harbor/.robur/stop_reason` read
   `human_blocked` from a previous killed run while the loop was actually
   running and committing normally.
3. **Uninterruptible waits.** `BACKOFF_LADDER` sleeps up to 14400s, `COOLDOWN`
   defaults to 14400s, and `wait_for_merge` polls for up to
   `MERGE_WAIT_TIMEOUT` = 259200s (three days). A stop must not wait those out.
4. **No single-instance guard.** `loop.pid` is written unconditionally,
   clobbering whatever was there, and `CLI.process_alive?` uses
   `Process.kill(0, pid)`, which cannot tell the real loop from a recycled PID.
   Observed live: 7 of 8 `loop.pid` files on this machine pointed at dead
   processes.

## Design constraints (non-negotiable — every task must hold these)

1. **Reuse the existing seams; add no new subsystems.** `Robur::Paths` owns
   every on-disk name. `Robur::State` owns every `.robur/` file read and write.
   `Robur::Observability` owns events.jsonl and the loop.log rendering. New
   behaviour goes through those three, never beside them.
2. **The watchdog poll loop is the drain mechanism.** `Turn.run` in
   `lib/robur/turn.rb` already polls every `POLL_INTERVAL` seconds, already
   checks several end conditions, and already kills the child correctly
   (`Sys::Proc#kill`: TERM, then a 0.05s poll to a 2s ceiling, then KILL).
   Adding one more condition is the entire mid-turn stop. Do not write a second
   supervisor, a thread, or a monitor process.
3. **A trap handler sets a flag and does nothing else.** Ruby requires signal
   handlers to be reentrant: no file I/O, no `Mutex`, no `Logger`, no `puts`.
   `CLI.emit` writes to loop.log and is therefore **forbidden inside a trap**.
   The handler increments an integer. Every decision happens later, at a poll.
4. **An operator stop is never a model failure.** The stop path must not call
   `health.strike!` or `health.bench!`. `ModelHealth` is one registry keyed by
   model id, shared across all chains, and it survives reset — a strike here
   would poison every future run on this machine.
5. **The epilogue always runs.** `stop_reason`, `run_end` and the metrics `run`
   row are the supervisor's only inputs. Every exit path must write them.
6. **Never discard work to clean up.** No `git reset`, no `git checkout --`, no
   `git stash`, no `git clean`, anywhere in this plan. A hard kill may have
   interrupted real work; discarding it is the one unrecoverable mistake
   available here.

## The shape (already decided — implement it, do not redesign it)

Two-stage stop, modelled on Sidekiq's TSTP/TERM, collapsed into
repeated-signal escalation:

| Level | Trigger | Behaviour |
|---|---|---|
| 0 running | nothing | normal |
| 1 **drain** | stop file exists, or 1st SIGINT/SIGTERM | finish the current turn, run its commit gate, then exit before starting the next turn |
| 2 **abort** | 2nd signal, or stop file containing `now` | terminate the agent child immediately, salvage green work, exit |

One flag object (`Robur::Lifecycle`), one stop file (`.robur/stop`), three
places that check it: the top of the turn loop, `Turn.run`'s poll loop, and
every long sleep. Level 2 still routes through `Sys::Proc#kill`'s existing
TERM→KILL escalation, so even an abort is not a hard kill of the agent.

Single-instance is `flock(LOCK_EX|LOCK_NB)` on `loop.pid`. The kernel releases
the lock when the process dies, so unlike a PID file it cannot go stale and is
immune to PID reuse.

---

## Milestone 0 — the flag and the file (serial)

> Nothing in later milestones works until this is green.

- [ ] T0.1 (trivial, serial) add the stop-file name and its State accessors
      touches: lib/robur/paths.rb, lib/robur/state.rb, test/state_test.rb
      do: `Robur::Paths` is the only place an on-disk name may be written. In
          `lib/robur/paths.rb`, next to the existing `def state_file(repo_dir, name)`,
          add `def stop_file(repo_dir) = state_file(repo_dir, "stop")`. It needs
          no legacy `.ratchet` twin, because `ensure_state_dir!` already leaves
          `.ratchet` as a symlink to `.robur`. Then in `lib/robur/state.rb`, add
          three module_function methods next to the existing
          `read_stop_reason`/`write_stop_reason` pair, using the same private
          helpers that file already defines (`first_line`, `write_line`,
          `state_path`). Reads return nil when the file is missing; writes never
          raise. Copy the snippet below literally.
      snippet:
          def read_stop(repo_dir)
            first_line(repo_dir, "stop")
          end

          def write_stop(repo_dir, mode)
            write_line(repo_dir, "stop", mode)
          end

          def clear_stop(repo_dir)
            File.unlink(state_path(repo_dir, "stop"))
          rescue StandardError
            nil
          end
      accept:
          Given a repo directory with no stop file
          When State.read_stop is called
          Then it returns nil and raises nothing
          Given State.write_stop(dir, "now") has been called
          When State.read_stop is called
          Then it returns "now", and after State.clear_stop it returns nil
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: do not touch Config::ALLOWLIST; do not add a legacy .ratchet
          name for the stop file

- [ ] T0.2 (normal, serial) add Robur::Lifecycle with the stop level
      touches: lib/robur/lifecycle.rb, lib/robur/cli.rb, exe/robur, test/lifecycle_test.rb
      do: Create the NEW file `lib/robur/lifecycle.rb` containing exactly the
          snippet below and nothing more — signals and interruptible sleep are
          added by T0.3, do not write them now. `level` is 0 (running), 1
          (drain) or 2 (abort). Then add `require "robur/lifecycle"` to
          `lib/robur/cli.rb` next to its other requires, AND add the matching
          require line to `exe/robur`. Both are required; `exe/robur` resolves
          lib/ beside itself and crashes at runtime if the require is missing.
          Create `test/lifecycle_test.rb` following the shape of
          `test/state_test.rb`: `require "test_helper"`, `require "robur/lifecycle"`,
          a class inheriting `Minitest::Test`, and `Dir.mktmpdir` for the repo.
      snippet:
          require "robur/state"

          module Robur
            class Lifecycle
              def initialize(dir)
                @dir = dir
                @signals = 0
              end

              def level
                file = Robur::State.read_stop(@dir)
                from_file = file.nil? ? 0 : (file.match?(/\A(now|abort)/) ? 2 : 1)
                [@signals, from_file].max
              end

              def stop_requested? = level.positive?
              def abort? = level >= 2
            end
          end
      accept:
          Given a Lifecycle for a directory with no stop file
          When level is read
          Then it is 0 and stop_requested? is false
          Given a stop file containing "now"
          When level is read
          Then it is 2 and abort? is true
          Given a stop file containing "drain"
          When level is read
          Then it is 1 and abort? is false
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: stdlib only; do NOT add signal handling or sleep in this task

- [ ] T0.3 (normal, serial) give Lifecycle a signal trap and an interruptible sleep
      touches: lib/robur/lifecycle.rb, test/lifecycle_test.rb
      do: Add exactly two methods to the `Robur::Lifecycle` class from T0.2,
          copying the snippet below. `install!` traps INT and TERM; the block
          must contain ONLY `@signals += 1` — Ruby requires reentrant signal
          handlers, so no printing, no file I/O, no `CLI.emit`, no method calls.
          `sleep` chunks a long wait into one-second slices and returns as soon
          as the level rises, because the loop sleeps up to 14400 seconds at a
          time and a stop request must not wait that out. Keep `sleep_it`
          injectable — the existing loop tests pass a fake sleep and would
          otherwise take hours.
      snippet:
          def install!
            @start_level = level
            trap("INT") { @signals += 1 }
            trap("TERM") { @signals += 1 }
            self
          end

          def sleep(seconds, sleep_it: Kernel.method(:sleep))
            remaining = seconds.to_f
            start = level
            while remaining.positive?
              slice = remaining > 1 ? 1 : remaining
              sleep_it.call(slice)
              return :interrupted if level > start
              remaining -= slice
            end
            :slept
          end
      accept:
          Given a Lifecycle whose level rises to 1 after the first slice
          When sleep(10) is called
          Then it returns :interrupted after about one slice, not ten
          Given a Lifecycle whose level never changes
          When sleep(3) is called
          Then it returns :slept after three slices
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: the trap block contains exactly one integer increment and
          nothing else; do not use Thread, Queue, or a self-pipe

- [ ] T0.4 (normal, serial) make Loop.run's epilogue run on every exit path
      touches: lib/robur/loop.rb, test/loop_test.rb
      do: In `lib/robur/loop.rb`, find the epilogue — the three consecutive
          statements starting with `obs.emit(:run_end, turns: turn)` and ending
          with the `CLI.metrics_append(dir, "run", ...)` call, just before the
          method's final `stop_reason == "gate_red" ...` line. That epilogue is
          the only thing the external supervisor reads, and today it is skipped
          whenever the method does not fall out of `loop do ... end` normally.
          Wrap the `loop do ... end` in `begin ... ensure ... end` and move
          those three statements into the `ensure`, leaving the final exit-code
          line outside it. Also change the initialisation `stop_reason = ""` near
          the top of the method to `stop_reason = "crashed"`, so an unexpected
          exception is recorded honestly instead of as an empty string. Finally,
          write that value to disk AT STARTUP too, right after the existing
          `File.write(Paths.state_file(dir, "last-log"), ...)` call, via
          `State.write_stop_reason(dir, "running")`. Reason, observed live on
          2026-09-04: stop_reason is written only in the epilogue, so a run that
          is SIGKILLed leaves the PREVIOUS run's verdict standing forever. The
          harbor repo sat with a stale `human_blocked` from 2026-09-02 while its
          loop was running and committing normally, which makes the external
          supervisor skip a healthy repo for a whole cycle. The ensure block
          overwrites "running" on every ordinary exit, so the word is only ever
          visible while a loop is actually alive or was hard-killed.
      accept:
          Given a run whose turn loop raises an unexpected exception
          When the process unwinds
          Then .robur/stop_reason contains "crashed", a metrics "run" row was
          appended, and the exception still propagates to the caller
          Given a repo whose stop_reason file says "human_blocked" from an
          earlier run
          When a new run starts
          Then stop_reason says "running" before the first turn is spawned
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: the existing stop_reason words (done, human_blocked,
          gate_red, progress_stalled, once, review_exceeded) keep their exact
          spelling — money-loop.sh matches on them; do not change the returned
          exit code mapping

---

## Milestone 1 — graceful stop (serial: these tasks all edit loop.rb)

- [ ] T1.1 (normal, serial) Turn.run ends the turn when an abort is requested
      touches: lib/robur/turn.rb, test/turn_test.rb
      do: In `lib/robur/turn.rb`, `Turn.run`'s poll loop already checks several
          end conditions and already kills the child correctly. Add ONE more.
          First add a keyword argument `stop_check: nil` to the `def self.run(...)`
          signature, next to the existing `early_tokens:`. Then, inside the
          `loop do`, find the existing deadline check, which is the block
          beginning with the line `if now - start >= turn_timeout`. Insert the
          snippet below immediately AFTER that block's `end`. `stop_check` is a
          callable returning the stop level. Only level 2 (abort) ends the turn
          — level 1 means drain, and draining means letting the current turn
          finish. Everything after the loop is unchanged: the existing
          `proc.kill(pid) || proc.reap(pid)` tail handles the child, which is
          why an abort is still a polite TERM-then-KILL and not a hard kill.
      snippet:
          if stop_check && stop_check.call >= 2
            reason = "stop-requested"
            detected = now
            break
          end
      accept:
          Given an agent stub that sleeps far longer than the poll interval
          When stop_check returns 2
          Then Turn.run returns with kill_reason "stop-requested" and the child
          process is no longer alive
          Given stop_check returns 1 and the stub exits on its own
          Then kill_reason is nil and the result is unchanged
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: do not reorder or modify the existing checks; do not change
          the token-seen reap-grace behaviour; stop_check must default to nil so
          every existing caller keeps working

- [ ] T1.2 (normal, serial) install Lifecycle in Loop.run and drain between turns
      touches: lib/robur/loop.rb, test/loop_test.rb
      do: In `lib/robur/loop.rb`, find the line
          `File.write(File.join(log_dir, "loop.pid"), "#{Process.pid}\n")`.
          Immediately after it, add `life = Robur::Lifecycle.new(dir).install!`
          and `Robur::State.clear_stop(dir)` — clearing first means a stop file
          left over from a previous session cannot instantly kill a fresh run.
          Add `require "robur/lifecycle"` at the top of the file with the other
          requires. Then, as the FIRST statement inside the `loop do` body
          (before `turn += 1`), add the snippet below, so a drain never starts a
          new turn. This task does NOT touch the Turn.run call or add an abort
          arm; T1.3 does that.
      snippet:
          if life.stop_requested?
            emit "stop requested — finishing cleanly, no new turn will start."
            stop_reason = "stopped"
            break
          end
      accept:
          Given a running loop and a stop file written between two turns
          When the loop reaches the top of its next iteration
          Then no further agent is spawned, .robur/stop_reason is "stopped",
          a metrics "run" row exists, and the process exits 0
          Given a stop file exists before a run starts
          When robur run begins
          Then the stop file is removed and the first turn runs normally
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: the word is exactly "stopped"; do not invent a new
          stop_reason value; do not change any other loop behaviour

- [ ] T1.3 (hard, serial) abort mid-turn without punishing the model
      touches: lib/robur/loop.rb, test/loop_test.rb
      do: In `lib/robur/loop.rb`, find the `result = Turn.run(cmd: cmd, ...)`
          call and add `stop_check: -> { life.level }` to its arguments, using
          the `life` object T1.2 created. Then insert the snippet below directly
          after that call, BEFORE the line that computes `status =`. It salvages
          any green work exactly as the existing `:timeout` arm does, then
          breaks. It deliberately does NOT call `health.strike!`,
          `health.bench!`, `health.record!` or `guard.record` — design
          constraint 4: `ModelHealth` is one registry keyed by model id, shared
          by every chain, and it survives reset, so striking a model because a
          human pressed Ctrl-C would poison every future run on the machine.
      snippet:
          if result.kill_reason == "stop-requested"
            emit "stop requested mid-turn — salvaging green work and stopping."
            commit_turn(turn, model, conf, plan, dir)
            stop_reason = "stopped"
            break
          end
      accept:
          Given a stop file containing "now" appears while a turn is running
          When the watchdog's next poll sees it
          Then the agent child is terminated, the commit gate runs once, and
          .robur/stop_reason is "stopped"
          Given the same abort
          When the run ends
          Then the model's bench and strike counts are unchanged from before
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: no strike, no bench, no health.record!, no guard.record on
          this path; place the block before `status =` so no classification runs

- [ ] T1.4 (normal, serial) make every long wait interruptible
      touches: lib/robur/loop.rb, test/loop_test.rb
      do: Three places in `lib/robur/loop.rb` wait long enough to sit on a stop
          request: the `sleep_it.call(backoff)` after the all-models-benched
          message (the `BACKOFF_LADDER` is 900/3600/14400 seconds), every
          `sleep_it.call(conf["SHORT_SLEEP"].to_i)` in the classification arms,
          and `wait_for_merge`, which calls `sleep_it.call(poll_secs)` with
          poll_secs defaulting to 300 in a loop bounded by 259200 seconds (three
          days). Replace each `sleep_it.call(N)` with
          `life.sleep(N, sleep_it: sleep_it)`. Keep passing `sleep_it` through —
          the existing tests inject a fake sleep and would otherwise run for
          hours. `wait_for_merge` does not have `life` in scope: add a keyword
          `life: nil` to its `def`, pass the loop's `life` at both call sites,
          and guard with `life ? life.sleep(...) : sleep_it.call(...)`. Also, at
          the top of `wait_for_merge`'s poll loop, `return 4 if life&.stop_requested?`.
          Callers already treat any nonzero as "did not merge", so no call site
          needs other changes.
      accept:
          Given all models are benched and the loop entered a 14400s backoff
          When a stop file appears
          Then the loop stops within about a second with stop_reason "stopped"
          Given wait_for_merge is polling an open PR
          When a stop file appears
          Then it returns 4 without waiting for the next poll interval
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: sleep_it stays injectable everywhere; do not change the
          ladder values or the poll and timeout defaults

- [ ] T1.5 (normal) add the `robur stop` command
      touches: lib/robur/cli.rb, exe/robur, test/cli_test.rb
      do: In `lib/robur/cli.rb`, find the command dispatch `case` — the run of
          `when "doctor"` / `when "status"` / `when "watch"` / `when "run"`
          branches. Add `when "stop"` calling a new `cmd_stop(dir)`. Write
          `cmd_stop` next to `cmd_status`. It writes the stop file and prints
          one line; it must NOT block and must NOT require a loop.log to exist,
          unlike `status` and `watch`. Support three forms: bare `robur stop`
          writes "drain"; `--now` writes "now"; `--clear` calls
          `State.clear_stop`. Read those from the already-parsed flags the same
          way the neighbouring commands read theirs. Add `stop` to the usage or
          help text listing the commands. AGENTS.md rule: if you add a require,
          add it to `exe/robur` as well.
      snippet:
          def cmd_stop(dir)
            dir = File.expand_path(dir || Dir.pwd)
            Paths.ensure_state_dir!(dir)
            if @clear_stop
              State.clear_stop(dir)
              puts "stop cleared for #{dir}"
            else
              mode = @stop_now ? "now" : "drain"
              State.write_stop(dir, mode)
              puts "#{mode} requested: wrote #{Paths.stop_file(dir)}"
            end
            0
          end
      accept:
          Given a repo directory with no loop.log
          When `robur stop -d DIR` runs
          Then .robur/stop contains "drain", the command exits 0, and it prints
          the path it wrote
          Given a stop file exists
          When `robur stop --clear -d DIR` runs
          Then the stop file is gone and the command exits 0
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: no new conf keys; do not make stop wait for the loop to exit

---

## Milestone 2 — one loop per tree, and honest recovery

- [ ] T2.1 (normal, serial) flock loop.pid so two loops cannot share one tree
      touches: lib/robur/lifecycle.rb, lib/robur/loop.rb, lib/robur/cli.rb, test/lifecycle_test.rb
      do: Two `robur run` processes on one worktree means two agents editing one
          tree — the worst failure available here — and nothing prevents it
          today. A PID file cannot fix it: `CLI.process_alive?` uses
          `Process.kill(0, pid)`, which cannot distinguish the real loop from a
          recycled PID, and a crash leaves the file behind. Observed on this
          machine: 7 of 8 loop.pid files pointed at dead processes. Use `flock`,
          which the kernel releases on process death and which therefore cannot
          go stale. Add the snippet below to `Robur::Lifecycle`. Then, in BOTH
          `Loop.run` and `CLI.run_once_loop`, replace the existing
          `File.write(File.join(log_dir, "loop.pid"), ...)` line with a call to
          it, and `CLI.die` with a message naming the holder when it returns
          false. Keep `status_liveness` on `kill(0)` — display and mutual
          exclusion are different questions and need no unification.
      snippet:
          def acquire_lock!(pid_path)
            @lock = File.open(pid_path, File::RDWR | File::CREAT)
            return false unless @lock.flock(File::LOCK_EX | File::LOCK_NB)
            @lock.truncate(0)
            @lock.write("#{Process.pid}\n")
            @lock.flush
            true
          end
      accept:
          Given a process holding the lock on a repo's loop.pid
          When a second robur run starts on the same repo
          Then it exits nonzero naming the holding pid and spawns no agent
          Given the holding process is killed with SIGKILL
          When a new robur run starts
          Then it acquires the lock and runs normally
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: the @lock File object must stay referenced for the process
          lifetime — if it is garbage collected the fd closes and the lock is
          silently released; keep loop.pid's format as one pid on one line,
          because `status` parses it

- [ ] T2.2 (normal, serial) report leftovers from an unclean previous exit
      touches: lib/robur/loop.rb, test/loop_test.rb
      do: The loop is already crash-tolerant at turn boundaries, because the
          tracker IS the state and a fresh run recomputes everything. Only one
          residue survives a hard kill silently: files left in the git index by
          a turn that never reached its commit gate. Add a small method
          `report_unclean_start(dir, obs)` to `Robur::Loop`, called from
          `Loop.run` after the lock is acquired and before the turn loop. It
          runs `Open3.capture3("git", "-C", dir, "diff", "--cached", "--name-only")`,
          and when the output is non-empty emits a `recovered` event and one
          `emit` line naming how many files are staged. Then it returns. That is
          all: leaving the files staged is correct, because the next turn's
          commit gate runs VERIFY_CMD over them, which is the right owner of
          that decision.
      accept:
          Given a repo whose git index holds two staged files at startup
          When robur run starts
          Then loop.log contains a line naming 2 staged files, the files are
          still staged, and the first turn proceeds normally
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: absolutely no git reset, checkout, stash or clean anywhere in
          this task — read-only with respect to the working tree and the index

- [ ] T2.3 (trivial) show the stop state in `robur status`
      touches: lib/robur/cli.rb, test/cli_test.rb
      do: In `lib/robur/cli.rb`, `status_report` builds a line beginning
          `out << (loop_status.start_with?("running") ? ...` from
          `status_liveness`. An operator needs to see that a loop is draining
          rather than wonder why it is still alive. Before that line, read
          `State.read_stop(dir)`; when it is non-nil, append " (aborting)" to
          `loop_status` if it starts with now or abort, otherwise " (draining)".
          This is a purely additive change to one rendered string.
      snippet:
          if (s = State.read_stop(dir))
            loop_status += s.match?(/\A(now|abort)/) ? " (aborting)" : " (draining)"
          end
      accept:
          Given a running loop and a stop file containing "drain"
          When robur status runs
          Then the Loop line reads "running (pid N) (draining)"
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: never write this text into loop.log — status_report greps
          that file and a status block inside it would poison the parser

---

## Milestone 3 — many loops at once

- [ ] T3.1 (hard, serial) fanout drains its children instead of orphaning them
      touches: lib/robur/loop.rb, test/loop_test.rb
      do: `Loop.fanout` launches up to FANOUT_MAX `robur run` children with
          `Process.spawn(..., chdir: wt_path)` and then blocks in the loop that
          calls `wait_pid`. It installs no traps, so `kill TERM <fanout-pid>`
          reaches only fanout: every child loop is orphaned, and each of those
          orphans its own agent — 2N runaway processes. Fix: build
          `life = Robur::Lifecycle.new(dir).install!` at the top of `fanout`,
          and replace the final `pids.each { |pid| wait_pid.call(pid) unless reaped[pid] }`
          line with the snippet below, which polls instead of blocking and
          writes a stop file into each worktree once a stop is requested. Each
          child then drains through its own T1.2/T1.3 path. CRITICAL: signal
          nothing. Write files. `Process.spawn` without `pgroup:` leaves the
          children in fanout's OWN process group, so `Process.kill(sig, -pgid)`
          would signal fanout and the operator's terminal too.
      snippet:
          notified = false
          remaining = pids.reject { |pid| reaped[pid] }
          until remaining.empty?
            if life.stop_requested? && !notified
              mode = life.abort? ? "now" : "drain"
              pairs.each { |wt_path, _b| Robur::State.write_stop(wt_path, mode) }
              emit "  stop requested — wrote #{mode} to #{pairs.size} worktree(s)"
              notified = true
            end
            remaining.reject! { |pid| Process.waitpid(pid, Process::WNOHANG) }
            life.sleep(1, sleep_it: sleep_it) unless remaining.empty?
          end
      accept:
          Given fanout has launched three child loops
          When a stop is requested
          Then a stop file appears in all three worktrees, fanout waits for all
          three pids to exit, and fanout_clean still runs afterwards
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: never signal a process group; keep `launch` and `wait_pid`
          injectable so the existing fanout tests still pass; fanout_clean's
          fail-toward-KEEP behaviour is unchanged — a stopped worktree with
          unpushed commits is kept, never removed

- [ ] T3.2 (trivial) record the concurrency guarantees in AGENTS.md
      touches: AGENTS.md
      do: Add ONE bullet to the "Design decisions" list in AGENTS.md, in the
          same voice as the bullets already there, so a future turn does not
          "simplify" the isolation away. State these three facts: (1)
          `CLI.project_slug` suffixes the repo basename with a checksum of its
          absolute path, so each worktree gets its own log dir and therefore its
          own loop.pid, stop file and lock; (2) the flock is per state dir, so N
          loops on N worktrees never contend, while two loops on ONE worktree
          are refused; (3) the stop file is per repo dir, which is why fanout
          writes one file per worktree instead of broadcasting a signal —
          signalling the process group would hit fanout itself.
      accept:
          Given AGENTS.md
          When the design-decisions section is read
          Then one bullet names project_slug, the per-state-dir flock and the
          per-repo stop file as what makes concurrent loops safe
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: documentation only, no code change; do not put loop protocol
          mechanics in AGENTS.md — that travels in the harness prompt

---

## Milestone 4 — make it legible

- [ ] T4.1 (normal) structured lifecycle events
      touches: lib/robur/observability.rb, lib/robur/loop.rb, test/observability_test.rb
      do: loop.log is a RENDERING of events.jsonl, never free-form prose parsed
          back with regexes, so each lifecycle transition must be an event
          first. In `lib/robur/observability.rb`, add three entries to the
          `RENDER` hash, following the exact lambda style of the entries already
          there: `stop_requested` (fields source and level), `stopped` (fields
          reason and turns) and `recovered` (field staged_files). Then emit them
          from the sites built in T1.2, T1.3 and T2.2, using the existing
          `obs.emit_event(...)` calls in loop.rb as the pattern. Adding new kinds
          is additive and safe.
      snippet:
          stop_requested: ->(f) { ["  stop requested (#{f[:source]}, level #{f[:level]})"] },
          stopped: ->(f) { ["  stopped: #{f[:reason]} after #{f[:turns]} turn(s)"] },
          recovered: ->(f) { ["  recovered: #{f[:staged_files]} file(s) left staged by a previous run"] },
      accept:
          Given a loop stopped by a stop file
          When events.jsonl is read
          Then it contains a stop_requested record and a stopped record naming
          reason "stopped", and loop.log shows one human line for each
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: do NOT reword any existing RENDER line — the `stats` command
          has a legacy adapter that parses those exact strings

- [ ] T4.2 (trivial) document the stop contract for operators
      touches: skills/robur/SKILL.md, LEARNINGS.md
      do: Add a short "Stopping a loop" section to `skills/robur/SKILL.md`,
          which is what an agent reads to operate the loop. Document the four
          behaviours: `robur stop` drains (finishes the current turn, commits if
          green, exits 0 with stop_reason "stopped"); `robur stop --now` aborts
          the current turn but still exits cleanly; `robur stop --clear` cancels
          a pending stop; and a second Ctrl-C escalates a drain to an abort.
          Then append one entry to LEARNINGS.md recording the operational
          consequence: stop_reason "stopped" falls into money-loop.sh's `*` arm,
          so a deliberate stop backs the repo off for an hour. That is right for
          a human stop, but a supervisor doing a restart must delete
          `.robur/loop-backoff` afterwards or the next cycle skips the repo.
          Note in the same entry that `loop-backoff` is written ONLY by
          money-loop.sh — robur's `State.read_loop_backoff`/`write_loop_backoff`
          have no callers.
      accept:
          Given skills/robur/SKILL.md
          When the stopping section is read
          Then it documents drain, abort, clear and the double-Ctrl-C
          escalation, and LEARNINGS.md records the loop-backoff consequence
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: documentation only; never edit ../ratchet or atlas/bin

---

## Definition of done

- Every task `[x]`, and VERIFY_CMD green on a clean checkout.
- `robur stop` on a running loop leaves: no surviving agent process, a
  stop_reason of `stopped`, a metrics `run` row, and either a green commit or
  cleanly staged work.
- A second `robur run` on a locked repo refuses instead of racing.
- SIGKILL of a loop leaves nothing that blocks the next `robur run`.
- A stale `stop_reason` from a previous run can never outlive the start of the
  next one.
- `fanout` under a stop request drains every child before exiting.

## Non-goals

- `robur restart`. Restart belongs to the supervisor: stop, wait for the lock
  to free, run. Two existing commands already compose into it.
- `robur stop --all` across every repo. fanout children are addressable by
  worktree path; a global sweep is speculative until something needs it.
- Editing `atlas/bin/money-loop.sh`. `stopped` is a value it already handles;
  the backoff consequence is documented in T4.2 instead.
- Changing `Config::ALLOWLIST`, the metrics column contract, or the spelling of
  any existing stop_reason value.
- Resuming a killed turn mid-flight. The tracker is the state and a fresh turn
  recomputes; turn-level checkpointing buys nothing.
