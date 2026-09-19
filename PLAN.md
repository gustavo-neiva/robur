<!-- class: MACHINE -->
# PLAN.fleet.md — robur grows its outer loop: one machine, many repos, forever

> Tracker grammar: `- [ ]` open → `- [IN PROGRESS]` → `- [x]` done.
> Tags: `(trivial|normal|hard)` routes the model tier, a REQUIRED non-first
> conventional-commit kind (`feat|fix|perf|refactor|docs|test|chore`) becomes
> the commit prefix, and `(serial)` forbids parallel siblings.

**What this delivers.** `robur run` drives ONE repo until it stops. Something
else has to decide which repo runs next, how often, and what happens when one
fails. Today that decision lives in a sibling Python repo (`../harbor`,
`harbor/loop/`) — 4,978 lines that shell out to `robur` and read robur's own
state files from the outside. This plan brings the decision inside: a **fleet**
layer that owns a roster of repos, gates each one, plans a cycle under budgets,
executes it with per-checkout locking, and repeats on a beat.

**Reference, read-only.** `../harbor/harbor/loop/` is the working implementation
this ports FEATURES from. Read it freely for behaviour and for the production
scars in its comments. **Never write a byte there.** Nothing in this plan
removes, edits or deprecates any harbor file; harbor keeps running unchanged
throughout, and the two implementations coexist until a human decides to cut
over. There is no cutover task in this plan.

**Port features, not implementations.** harbor/loop is a line-by-line port of a
bash script and still has bash's shape: free functions mutating a `_Cycle`
struct, a `dry_run_lines()` that renders decisions as tab-separated strings,
and an `eligibility()` that parses those strings back. It also re-implements
things robur already owns — a second `PLAN.md` parser (`loop/tracker.py` vs
`Robur::Plan`), a second `.robur.conf` reader (`loop/config.py`, whose own
docstring says *"keep the two in sync by hand"*), and a second model-health
registry that is documented as unable to tell a live bench from a dead one.
**None of that is ported.** Take the behaviour; call the module robur already
has.

**Explicitly dropped.** Telegram, the Svelte console, HTTP API routes, queue
drafts, `MONEY.md` board rewriting, the weekly critic, the publish dispatcher,
the 14-day stall watchdog, the session brief, the ideas pipeline, revenue
attribution, cost-in-BRL, and the SQLite run store (`loop/ingest_runs.py`).
Those are either estate rituals that belong to harbor or a separate
observability project. This plan is the orchestrator and nothing else.

---

## Design constraints (read before ANY task — non-negotiable)

1. **Stdlib only.** No gems, no Bundler, no Sorbet, no RBS. Minitest is
   pre-approved (it ships with Ruby).
2. **Never hardcode an on-disk name.** `.robur/`, `.robur.conf`, `~/.robur/`,
   `ROBUR_HOME` and every new fleet path resolve through `Robur::Paths` and
   nowhere else.
3. **Reuse the seams robur already has.** Tracker reads go through
   `Robur::Plan`. Files under `.robur/` go through `Robur::State`. Config goes
   through `Robur::Config`. Filesystem/clock/subprocess/HTTP go through
   `Robur::Sys` (injected, so tests never touch a real `$HOME`, clock or
   process). Terminal output goes through `Robur::Render`. A `Fleet::*` class
   that re-implements any of these is a failed task, not a shortcut.
4. **Fleet budget keys are GLOBAL-ONLY.** `MAX_RUNS_PER_CYCLE`,
   `MAX_PLANS_PER_CYCLE`, `AUTOPLAN_MIN_SECS`, `BACKOFF_BASE`, `BACKOFF_CAP`,
   `FLEET_INTERVAL`, `HEALTHCHECK_URL` are read from `~/.robur/conf` and ENV
   only. **Never add one to `Config::ALLOWLIST`** — `.robur.conf` is
   agent-writable, and an agent that can raise its own run budget or lower its
   own backoff has escaped the thing that bounds it.
5. **One planner, two renderers.** `Fleet::Planner` is PURE: it takes a roster
   and a gate and returns decisions. It never spawns, never writes, never
   touches `File`/`Dir`, and reads the clock only through an injected
   `Sys::Clock`. Anything on disk it needs — the pause flag, an autoplan stamp
   — is read by the CALLER or by `Gate` and handed in as a value. `--dry-run`
   and the real cycle consume the SAME decisions. There must never be a second
   code path that decides what runs — that divergence is why harbor's board
   reported `0 open` for repos its runner considered runnable.
6. **Spawn from the running process, never from `$PATH`.** A child turn is
   launched as `[<the ruby running now>, <this exe>, "run", repo]`. Harbor
   needed a 30-line `_robur_ok()` preflight because it shelled out to the bare
   name `robur`, and three multi-day outages (2026-09-04..07) were launchd
   resolving `#!/usr/bin/env ruby` to system Ruby 2.6. Resolving from the live
   process removes the MISATTRIBUTION, not the whole failure class: the
   supervisor's own launch is still `$PATH`-dependent, and a child that never
   starts is an environment fault that must fail the cycle and back off NO
   repo (see T3.3). Charging it to every repo is what turned three small
   config bugs into a multi-day outage harbor could not exit.
7. **`../harbor` is READ-ONLY.** Read it for reference; never write it.
8. **One task per turn.** Do the task, add its verify case, run `VERIFY_CMD`,
   mark `[x]`, print `STEP_COMPLETE`.

### The shape being built

```
lib/robur/fleet.rb              Fleet.cycle / Fleet.dry_run — the two entry points
lib/robur/fleet/roster.rb       fleet.conf: read + classify (read-only; humans edit it)
lib/robur/fleet/gate.rb         one repo's verdict (pure reads, no decisions)
lib/robur/fleet/backoff.rb      the failure ladder, over Robur::State
lib/robur/fleet/lock.rb         one writer per checkout (flock)
lib/robur/fleet/planner.rb      PURE: roster + gate + budgets -> [Decision]
lib/robur/fleet/cycle.rb        executes decisions, records outcomes
lib/robur/fleet/notifier.rb     NOTIFY_CMD, deduped per (repo, reason)
lib/robur/fleet/render.rb       PURE terminal rendering of a decision board
lib/robur/fleet/supervisor.rb   --every: the perpetual beat
test/fleet/*_test.rb            one test file per class above
```

## Milestone 3 — the cycle executes the plan

> The first milestone that spawns anything. `Fleet::Cycle` consumes
> `Planner#cycle_plan` and does exactly what it says — it makes no decisions of
> its own. Tasks sharing `cycle.rb` are `(serial)`.

- [x] T3.1 (normal, feat) one writer per checkout, and a busy repo is skipped not queued
      touches: lib/robur/fleet/lock.rb, test/fleet/lock_test.rb
      do: Add `Fleet::Lock.acquire(repo)` -> a `Lease` with `#release`, or `nil`
          immediately when the checkout is already locked. Use a non-blocking
          `flock(LOCK_EX | LOCK_NB)` on `State.state_path(repo, "loop.lock")`,
          writing the holder pid into the file so `Lock.holder_pid(repo)` can
          report who has it. Never wait and never force: a contended checkout is
          skipped for this cycle and retried on the next beat. This is what stops
          a cycle from moving `HEAD` underneath a human's live session in the
          same tree — harbor's own architecture review recorded `HEAD` moving
          three times under a read-only analysis before this existed (L3 in
          `../harbor/docs/research/2026-09-11-agentic-harness.md`). Follow the
          flock pattern already in `Robur::Lifecycle#acquire_lock!`.
      snippet:
          f.flock(File::LOCK_EX | File::LOCK_NB) or return nil
      accept:
          Given a lease already held on a repo
          When Lock.acquire is called again for that repo
          Then it returns nil without blocking, and holder_pid reports the first holder
          And after the first lease is released, acquire succeeds
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — new test/fleet/lock_test.rb takes two leases in one process and one via a
              forked child, asserting non-blocking failure and clean re-acquisition.
      constraints: lock path via Robur::State/Paths; never block, never break a lock;
                   always release in an ensure; stdlib only.

- [ ] T3.2 (hard, feat, serial) a child turn is spawned from the running ruby, never from $PATH
      touches: lib/robur/fleet/cycle.rb, test/fleet/cycle_test.rb
      do: Add `Fleet::Cycle.new(planner:, spawner:, lock: Fleet::Lock, out:)` and
          `#spawn(repo, *argv)` returning the child's exit status. The DEFAULT
          spawner builds the command from the LIVE process, never from a name
          lookup: `RbConfig.ruby` for the interpreter, and for the program the
          EXACT expression `EXE = File.expand_path("../../../exe/robur", __dir__)`
          from `lib/robur/fleet/cycle.rb` — written out because `$0` and
          `$PROGRAM_NAME` differ under symlinks, binstubs and shims, and this is
          the one line design constraint 6 rests on. Tagged hard for that reason:
          shelling out to the bare name `robur` gave three multi-day outages
          (2026-09-04..07) where launchd's PATH resolved the shebang to system
          Ruby 2.6, and each was wrongly charged to every repo as a run failure.
          A separate process is still the right isolation boundary — one repo
          crashing must not take the fleet down — but the binary is resolved, not
          searched. `system` returns NIL when the child never started and FALSE
          when it ran and failed; return the distinct sentinel `:spawn_error` for
          nil, because T3.3 must not charge an environment fault to a repo.
          The spawner is injected so no test ever launches a real turn.
      snippet:
          EXE = File.expand_path("../../../exe/robur", __dir__)
      accept:
          Given the default spawner
          When Cycle#spawn builds the command for a repo
          Then argv[0] is RbConfig.ruby and argv[1] is an executable file that exists,
          And the literal string "robur" is never used as a bare command name,
          And a child that cannot be started yields :spawn_error, not an exit code
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — new test/fleet/cycle_test.rb asserts File.executable?(Cycle::EXE), the
              argv shape, the :spawn_error sentinel, and that an injected spawner
              receives the argv with no process launched.
      constraints: never `system("robur", ...)` or exec a bare name; never $0/$PROGRAM_NAME;
                   injected spawner in tests; stdlib only (RbConfig is stdlib).

- [ ] T3.3 (hard, feat, serial) a repo's stop reason decides its backoff, and a deliberate stop costs nothing
      touches: lib/robur/fleet/cycle.rb, test/fleet/cycle_test.rb
      do: Add `Cycle#record_outcome(repo, exit_status)` applying the policy table
          below, reading `Gate#stop_reason` after the child exits. `done` clears
          the backoff. `human_blocked` marks the repo skipped for the rest of the
          cycle and notifies (T5.3 wires the notifier; leave a hook). `stopped`
          does NEITHER bump nor clear — a human ran `robur stop`, and that is an
          instruction, not a failure; backing off for it silently costs the next
          scheduled cycle too. `:spawn_error` (T3.2's sentinel: the child never
          started) bumps NOTHING and fails the whole cycle loudly — a missing
          interpreter or exe is a property of this machine, not of any repo, and
          charging it per repo is exactly how harbor turned three small config
          bugs into a multi-day outage every repo then had to climb out of.
          `gate_red`, `progress_stalled`, `review_exceeded` and any real nonzero
          exit bump the ladder. Tagged hard: `stopped` and `:spawn_error` are the
          non-obvious rows and every other one is easy to get subtly wrong.
          Ported from `../harbor/harbor/loop/runner.py:_run_repo` + `run_cycle`.
      snippet:
          when :spawn_error then fail_cycle(repo, :environment) # bump nothing
          when "stopped"      then :no_change
          when "human_blocked" then skip_rest_of_cycle(repo)
      accept:
          Given a repo whose child exits 0 with stop_reason "stopped"
          When Cycle#record_outcome runs
          Then the loop-backoff file is neither created nor modified
          And with stop_reason "done" an existing backoff file is removed
          And with stop_reason "gate_red" the backoff count increments by one
          And with :spawn_error no repo's backoff file is touched and the cycle is red
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — test/fleet/cycle_test.rb covers done, stopped, human_blocked, gate_red,
              progress_stalled, a nonzero exit with no stop_reason file, and that
              :spawn_error across a 3-repo roster writes zero backoff files.
      constraints: backoff writes go through Fleet::Backoff; stop_reason via Gate;
                   an environment fault never backs off a repo; stdlib only.

- [ ] T3.4 (normal, feat, serial) `robur fleet` runs a real cycle and returns the cycle's status
      touches: lib/robur/fleet/cycle.rb, lib/robur/fleet.rb, lib/robur/cli.rb,
               test/fleet/cycle_test.rb
      do: Add `Cycle#run` executing three phases in order: `cycle_plan[:runs]`,
          then `cycle_plan[:plans]` (`spawn(repo, "plan", "--auto", repo)`), then
          a SECOND run pass. The second pass is a NEW `Planner` built by the
          CYCLE, not a third method on the planner: same roster and budget, a
          fresh `gate_for` (the plan turns have since added tasks) and
          `already_ran:` set to the repos run in pass one, which T2.1 turns into
          `:skip` reason `:once_per_cycle`. Exactly two run passes, never three:
          a plan turn only ADDS tasks, so a third finds nothing a second could
          not. Every spawn is wrapped in `Lock.acquire` and released in an
          `ensure`; a `nil` lease logs `lock held by pid N` and skips that repo
          for the cycle. Return 0 when every child exited 0, else the last
          nonzero status. Wire `Fleet.cycle` and make a bare `robur fleet`
          call it, replacing T0.3's "not implemented yet" stub. One repo raising
          must not abort the cycle — rescue per repo, record it as a failure, and
          carry on to the next.
      snippet:
          Planner.new(**base, gate_for: fresh_gate_for, already_ran: ran).cycle_plan[:runs]
      accept:
          Given a roster of two runnable repos and an injected spawner returning 0 then 1
          When `robur fleet` runs
          Then both repos were spawned, the exit status is 1,
          And a repo caught up in pass one with tasks after its plan turn runs in pass three,
          And a repo already run in pass one is not spawned again,
          And a repo whose lock is already held is skipped without spawning
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — test/fleet/cycle_test.rb drives a full cycle with an injected spawner,
              asserting the three-phase order, once-per-cycle, lock skip, per-repo rescue.
      constraints: never spawn without a lease; always release in ensure; injected spawner
                   in tests — the suite must launch no real turn; stdlib only.

- [ ] T3.5 (normal, feat, serial) the autoplan stamp is written only after a plan turn actually ran
      touches: lib/robur/fleet/cycle.rb, test/fleet/cycle_test.rb
      do: After a `:plan` decision spawns successfully, touch
          `State.state_path(repo, "autoplan.stamp")` so T2.2's per-repo rate
          limit advances. Write it only on a spawn that happened — stamping a
          skipped or lock-contended repo would silence its next six hours of
          planning for work that was never attempted. A plan turn that produces
          no open tasks is a CORRECT outcome for a genuinely caught-up repo: log
          it plainly and do not bump the backoff, because an honest empty plan
          is not a failure.
      snippet:
          FileUtils.touch(Robur::State.state_path(repo, "autoplan.stamp"))
      accept:
          Given a caught-up repo whose plan turn is spawned and exits 0 producing no tasks
          When the cycle finishes
          Then autoplan.stamp exists with a current mtime and no backoff was recorded
          And a repo skipped for lock contention has no stamp written
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — test/fleet/cycle_test.rb asserts stamp-on-spawn, no-stamp-on-skip,
              and that an empty plan result records no failure.
      constraints: stamp path via Robur::State; stdlib only.

## Milestone 4 — the operator's knobs

> The two things a human does between beats that a text editor cannot do:
> stop the beat, and clear a stale backoff ladder. Everything else about
> `fleet.conf` and `PLAN.md` — adding, removing, parking, unparking a repo,
> handing a parked task back — is a line edit in a human-owned file, and the
> operator is already in an editor. These verbs existed in harbor only because
> Telegram has no editor; a terminal does. See Non-goals.

- [ ] T4.1 (trivial, feat, serial) `robur fleet pause` and `resume` stop and restart the beat
      touches: lib/robur/fleet.rb, lib/robur/cli.rb, test/fleet/cli_test.rb
      do: Add `robur fleet pause` (create `Paths.fleet_paused_flag`) and
          `robur fleet resume` (unlink it, tolerating absence). T2.3 already
          makes the planner honour the flag, so this task only adds the two
          verbs and their output lines. Print the resulting state so a human
          gets confirmation rather than silence. Tagged trivial: two file
          operations behind two subcommands.
      snippet:
          when "pause"  then FileUtils.touch(Paths.fleet_paused_flag)
      accept:
          Given no pause flag exists
          When `robur fleet pause` then `robur fleet --dry-run` run
          Then the dry run reports the fleet as paused
          And after `robur fleet resume` it reports the normal board again
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — new test/fleet/cli_test.rb asserts pause, resume, and resume-when-absent.
      constraints: flag path via Robur::Paths; resume must not raise when already resumed.

- [ ] T4.2 (trivial, feat, serial) `robur fleet retry` clears every backoff so a fixed fleet runs now
      touches: lib/robur/fleet.rb, lib/robur/cli.rb, test/fleet/cli_test.rb
      do: Add `robur fleet retry`: for every active roster entry, call
          `Fleet::Backoff#clear!` and print how many were cleared. This is the
          "I just fixed the thing that was failing, stop waiting" button — after
          an environment fault every repo can be sitting on a 4h ladder for a
          cause that no longer exists, and without this the only cure is waiting
          it out. Parked repos are skipped. Tagged trivial: a loop and a delete.
      snippet:
          cleared = roster.active.count { |e| Backoff.new(e.path).clear! }
      accept:
          Given two active repos with backoff files and one parked repo with one
          When `robur fleet retry` runs
          Then it prints "cleared 2" and the parked repo's backoff file still exists
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — test/fleet/cli_test.rb asserts the count, the deletions, and the parked skip.
      constraints: clears go through Fleet::Backoff, never File.unlink on a path built here.

## Milestone 5 — perpetual, and loud when it cannot be

> The fleet becomes something you start once. A cycle is still a single
> process-worth of work, so `robur fleet` stays cron/launchd-friendly; `--every`
> adds the supervisor for the common case where you just want it running.

- [ ] T5.1 (hard, feat, serial) `robur fleet --every 15m` keeps running and drains on Ctrl-C
      touches: lib/robur/fleet/supervisor.rb, lib/robur/cli.rb, test/fleet/supervisor_test.rb
      do: Add `Fleet::Supervisor.new(interval:, cycle:, lifecycle:, clock:)` and
          `#run`: execute one cycle, sleep the interval, repeat. `interval`
          defaults to `Fleet.budget.interval` (`FLEET_INTERVAL`); `--every`
          overrides it and parses `900`, `15m`, `2h`. Reuse
          `Robur::Lifecycle#install!` and its INTERRUPTIBLE `#sleep` so one
          Ctrl-C finishes the current cycle and exits and a second aborts — do
          NOT call `Kernel.sleep`, which would make a 15-minute beat take up to
          15 minutes to respond to a signal. `Lifecycle.new` takes a dir it
          reads a stop file from; the fleet has no repo, so pass
          `Paths.fleet_log_dir` — that also makes `robur stop` on the fleet a
          later one-liner. A cycle that RAISES must be RESCUED, logged, and
          followed by the next beat: the supervisor's whole job is to outlive a
          bad night. Tagged hard for the signal semantics.
      snippet:
          loop { begin; cycle.run; rescue => e; log(e); end
                 break if lifecycle.stop_requested?; lifecycle.sleep(interval) }
      accept:
          Given an injected cycle that raises on its first call and returns 0 after
          When Supervisor#run executes with a stub lifecycle stopping after 3 beats
          Then the cycle was invoked 3 times and the raise did not end the supervisor
          And a stop requested during the sleep ends it without waiting out the interval
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — new test/fleet/supervisor_test.rb with injected cycle, clock and lifecycle;
              the test must complete in well under a second (no real sleeping).
      constraints: use Robur::Lifecycle#sleep, never Kernel.sleep; a raising cycle never
                   ends the supervisor; stdlib only.

- [ ] T5.2 (normal, feat, serial) a dead-man ping proves the beat is alive, not just that it started
      touches: lib/robur/fleet/cycle.rb, test/fleet/cycle_test.rb
      do: When `HEALTHCHECK_URL` is set in the global conf or ENV, ping
          `<url>/start` FIRST thing in `Cycle#run`, then close the pair at the
          end: the bare URL on a green cycle, `<url>/fail` on a red one. Use the
          injected `Sys::Http`; a failed ping is logged and never fails the
          cycle. The pair is the point — pinging only at the start cannot tell a
          healthy cycle from one that HANGS. When the key is unset, print a LOUD
          warning rather than a routine line: harbor ran blind for two days
          because the switch was silently off after a path change, and the
          switch was the only thing watching (`../harbor/harbor/loop/runner.py`,
          the `no HEALTHCHECK_URL` branch). The ping happens BEFORE the pause
          check, because a deliberate pause is not a dead schedule.
      snippet:
          http.get("#{url}/start") rescue nil
      accept:
          Given HEALTHCHECK_URL is set and every child exits 0
          When Cycle#run completes
          Then the injected Http received "<url>/start" then "<url>", in that order
          And on a nonzero cycle the second call is "<url>/fail"
          And with the key unset a warning naming the global conf is printed
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — test/fleet/cycle_test.rb asserts the ordered pair, the fail variant,
              the unset warning, and that an Http raise does not fail the cycle.
      constraints: HEALTHCHECK_URL is global-conf/ENV only, never a repo-conf key;
                   injected Sys::Http; a ping failure must never raise out of the cycle.

- [ ] T5.3 (normal, feat, serial) a repo blocked on a human nudges daily, not every beat and not once ever
      touches: lib/robur/fleet/notifier.rb, lib/robur/fleet/cycle.rb, test/fleet/notifier_test.rb
      do: Add `Fleet::Notifier.new(clock:)` with `#notify_once(repo, key, msg)`:
          send unless `State.state_path(repo, "last_notified")` already holds
          `key` AND its mtime is newer than `RENOTIFY_SECS` (86400); write the
          marker either way. `key` is `"<task_id>\t<reason>"`, so a new task or
          reason always sends. BOTH halves are load-bearing: without the key a
          repo stuck on one question sends 96 times a day, and without the
          24h expiry it sends exactly once — harbor measured an unanswered block
          sitting 46 hours against a 6-hour assumption because the single
          notification scrolled away (`runner.py:_notify_once`). Delivery goes
          through `Robur::Observability#notify_human`, which already spawns
          NOTIFY_CMD detached with the message as `$1`, reads the key from the
          trusted conf only, and never raises or blocks — do not re-implement it
          over `Sys::Proc#capture`, which BLOCKS the cycle. Wire the
          `human_blocked` and `gate_red` hooks left in T3.3.
      snippet:
          RENOTIFY_SECS = 86_400
      accept:
          Given a repo blocked on T3.1 that notifies on one cycle
          When a second cycle an hour later finds the same task still blocked
          Then no second notification is sent
          And when 25 hours have passed a nudge is sent again
          And when the blocked task id changes, a notification is sent immediately
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — new test/fleet/notifier_test.rb asserts dedupe, the 24h re-send with an
              injected clock, re-send on key change, and that a failing command
              does not raise.
      constraints: delivery via Observability#notify_human, never a second spawn path;
                   NOTIFY_CMD never added to Config::ALLOWLIST; injected clock; no HTTP.

- [ ] T5.4 (normal, feat, serial) a fleet paused long enough to be forgotten says so
      touches: lib/robur/fleet/cycle.rb, test/fleet/cycle_test.rb
      do: When the pause flag is older than `PAUSE_REMINDER_DAYS` (7), notify
          once a day through T5.3's `Notifier` naming how long it has been
          paused, then carry on skipping the cycle. Nothing here resumes the
          fleet — only the human does that. This closes the hole T5.2 opens on
          purpose: the healthcheck pings BEFORE the pause check, so a paused
          fleet reads green to every dashboard forever. Harbor sat paused for 30
          hours with every dashboard green before this existed
          (`../harbor/harbor/loop/runner.py:_pause_reminder`), and a pause that
          old is almost always forgotten rather than intended. Use the flag's
          own mtime as the record and the notifier's key expiry as the throttle
          — no new stamp file, no new format to corrupt.
      snippet:
          days = ((clock.now - File.mtime(Paths.fleet_paused_flag)) / 86_400).to_i
      accept:
          Given a pause flag whose mtime is 9 days old
          When a cycle runs
          Then one notification naming "paused 9 days" is sent and the cycle still skips
          And a second cycle an hour later sends nothing
          And a pause flag 2 days old sends nothing at all
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — test/fleet/cycle_test.rb covers under-threshold, over-threshold, and the
              daily throttle, all with an injected clock.
      constraints: never resume the fleet; reuse Fleet::Notifier's dedupe, do not add a
                   stamp file; flag path via Robur::Paths; stdlib only.

- [ ] T5.5 (hard, feat, serial) the supervisor restarts itself after a turn rewrites its own code
      touches: lib/robur/fleet/supervisor.rb, lib/robur/fleet/cycle.rb,
               test/fleet/supervisor_test.rb
      do: A long-lived `--every` supervisor holds robur's code in memory, so the
          moment a turn commits to robur's OWN checkout the fleet keeps running
          the old `Fleet::*` forever — it cannot pick up the fix it just wrote.
          Have `Cycle#run` record whether any spawn advanced `HEAD` in the
          checkout robur itself is running from (compare `git rev-parse HEAD`
          before and after that one repo, via `Sys::Proc`), and expose it as
          `Cycle#self_updated?`. `Supervisor#run` breaks the loop cleanly after
          a GREEN cycle that set it, exiting `RESTART_EXIT_STATUS` (75) so
          launchd/systemd respawns into the new code; a red cycle never
          restarts, because exiting on a failure would loop a crash. Tagged hard
          because the wrong version of this restarts on every commit anywhere.
          Ported from `../harbor/harbor/loop/runner.py:_new_head` + RESTART_EXIT_STATUS.
      snippet:
          RESTART_EXIT_STATUS = 75
      accept:
          Given the roster contains the checkout this process is running from
          When a green cycle's turn commits to that checkout
          Then Supervisor#run stops after that cycle and exits 75
          And a commit in any OTHER repo does not stop the supervisor
          And a RED cycle that touched its own checkout keeps beating
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — test/fleet/supervisor_test.rb drives all three cases with a stub cycle;
              no git and no real process is invoked.
      constraints: restart only on a GREEN cycle and only for robur's own checkout;
                   git reads via Sys::Proc; stdlib only.

## Milestone 6 — reading the fleet without a browser

> The console is not ported. These three tasks are the replacement: text that
> answers the two questions an operator actually has — what is it doing, and
> what is waiting on me. All three are `(serial)`: they share `fleet.rb`,
> `cli.rb`, `render.rb` and `cycle.rb` with milestones 0-5.

- [ ] T6.1 (normal, feat, serial) `robur fleet status` shows the whole fleet on one screen
      touches: lib/robur/fleet/render.rb, lib/robur/fleet.rb, lib/robur/cli.rb,
               test/fleet/render_test.rb
      do: Add `robur fleet status`: one line per roster entry with name, verdict,
          open/done task counts, stop reason, backoff expiry as a relative
          duration, and whether a lock is currently held. Below it, a `waiting on
          you` section listing every repo whose verdict is `:human_block` or
          `:class_gate` with its parked task id and question line. Render with
          `Robur::Render` helpers (`bar`, `fmt_dur`, the colour wrappers) so the
          output matches `robur status` rather than inventing a second house
          style. Keep `Fleet::Render` pure — it takes rows and returns a string;
          `Fleet` gathers the data.
      snippet:
          "#{name.ljust(w)}  #{verdict.ljust(14)}  #{open}/#{total}  #{Render.fmt_dur(secs)}"
      accept:
          Given a roster with one runnable repo, one backed off, and one human-blocked
          When `robur fleet status` runs
          Then each repo has a line naming its verdict,
          And the backed-off repo shows a relative expiry, not a raw epoch,
          And the human-blocked repo also appears under "waiting on you"
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — test/fleet/render_test.rb asserts column alignment and the waiting section.
      constraints: Fleet::Render stays pure; reuse Robur::Render, do not reimplement bars
                   or duration formatting; read-only — status never writes.

- [ ] T6.2 (normal, feat, serial) every cycle decision lands in events.jsonl, not just in prose
      touches: lib/robur/fleet/cycle.rb, lib/robur/observability.rb, test/fleet/cycle_test.rb
      do: Emit five events per cycle through the existing `Robur::Observability`,
          constructed against `Paths.fleet_log_dir`: `fleet_start` (roster size,
          budgets), `fleet_decision` (repo, action, reason), `fleet_spawn` (repo,
          argv), `fleet_exit` (repo, status, stop_reason), `fleet_end` (status,
          runs, plans, skips). `Observability#emit` does `RENDER.fetch(kind)` and
          raises KeyError on an unknown kind, so this task MUST add a lambda per
          kind to the `RENDER` table — without them the best-effort rescue below
          swallows every event and the feature is a silent no-op that still
          passes a loose test. The log line is a RENDERING of the event, never
          prose parsed back with regexes: that is the module's contract and what
          lets a later observability project read fleet history without the 1,290
          lines of log archaeology harbor needed
          (`../harbor/harbor/loop/ingest_runs.py`). Telemetry is best-effort — a
          failed emit is logged and never fails the cycle it describes.
      snippet:
          fleet_decision: ->(f) { ["  #{f[:repo]}: #{f[:action]} (#{f[:reason]})"] },
      accept:
          Given a cycle over two repos, one run and one skipped for backoff
          When the cycle completes
          Then events.jsonl holds fleet_start, two fleet_decision records, one
          fleet_spawn, one fleet_exit and one fleet_end, each carrying a run id
          And loop.log holds one rendered human line per event, none of them blank
          And an emit that raises does not change the cycle's exit status
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — test/fleet/cycle_test.rb parses the emitted JSONL, asserts the event
              sequence, asserts every fleet kind resolves in RENDER (no KeyError),
              and covers the best-effort rescue.
      constraints: use Robur::Observability, do not add a second event writer; every event
                   carries a run id; telemetry never raises out of the cycle.

- [ ] T6.3 (trivial, docs, serial) README and the conf example document the fleet as a first-class half
      touches: README.md, templates/robur.conf.example, AGENTS.md
      do: Add a "The fleet" section to `README.md` after "The mental model":
          `fleet.conf` is the roster — one repo path per line, `#` before a path
          parks it, and you EDIT IT IN AN EDITOR, there are no add/remove verbs.
          `robur fleet --dry-run` explains the next cycle, `robur fleet` runs
          one, `robur fleet --every 15m` runs forever, and the operator verbs are
          pause/resume/retry/status. State plainly that the fleet budget keys
          (`MAX_RUNS_PER_CYCLE`, `MAX_PLANS_PER_CYCLE`, `AUTOPLAN_MIN_SECS`,
          `BACKOFF_BASE`, `BACKOFF_CAP`, `FLEET_INTERVAL`, `HEALTHCHECK_URL`)
          live ONLY in the human-owned `~/.robur/conf`, and say why: an agent
          that could raise its own run budget has escaped the thing that bounds
          it. Add the same note to `templates/robur.conf.example` beside the
          existing `NOTIFY_CMD` paragraph, which makes the identical argument.
      snippet:
          ## The fleet
      accept:
          Given a reader who has only run `robur run`
          When they read README.md
          Then they can configure a roster and start a perpetual fleet without
          reading source, and they know which keys are global-only and why
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
              — docs only; the gate must stay green.
      constraints: documentation only, no behaviour change; do not add any fleet key to
                   Config::ALLOWLIST while editing the conf example.

## Definition of done

- Every task `[x]`; `VERIFY_CMD` green on a clean checkout.
- `robur fleet --dry-run` explains, for every repo in the roster, exactly what
  the next cycle will do and why — with no side effects.
- `robur fleet` executes that plan: locks each checkout, spawns one child per
  repo, applies the outcome policy, and exits with the cycle status.
- `robur fleet --every 15m` runs that forever, survives one repo failing and one
  raising cycle, drains cleanly on Ctrl-C, and restarts itself after a turn
  rewrites robur's own code.
- An environment fault — a child that never starts — fails the cycle and backs
  off NO repo.
- Every budget comes from `~/.robur/conf`/ENV; nothing in the fleet reads a
  repo `.robur.conf`, and `Config::ALLOWLIST` is unchanged.
- `robur fleet status` is readable without a browser.
- `../harbor` is byte-identical to its state at the start of this plan.

## Non-goals

- **No cutover.** harbor keeps running its own loop. Nothing here disables,
  edits or deletes harbor code. Switching launchd over is a later human call.
- **No durable run store.** No SQLite, no `runs`/`turns` tables, no port of
  `ingest_runs.py`. `events.jsonl` + `metrics.tsv` stay the record.
- **No Telegram, no HTTP API, no web console.** The interfaces are the CLI and
  `NOTIFY_CMD`.
- **No estate rituals.** No queue drafts, no `MONEY.md` board, no critic, no
  stall watchdog, no publish dispatcher, no brief, no ideas pipeline.
- **No new model-selection or tier logic.** The fleet decides WHICH repo runs;
  `Robur::Loop` keeps deciding everything about HOW a turn runs.
- **No parallel repo execution.** One repo at a time per cycle, like today.
  `PARALLEL`/`FANOUT` stay per-repo concerns.
- **No changes to `Config::ALLOWLIST`.** See constraint 4.
- **No roster-editing verbs.** No `fleet add/remove/park/unpark`, and therefore
  no byte-preserving writer in `Roster` — it stays a reader. `fleet.conf` is one
  repo path per line in a human-owned file; `#` before a path parks a repo and
  `$EDITOR` preserves every comment for free. Harbor needed these because
  Telegram has no editor. If a roster ever needs programmatic edits, port
  `../harbor/harbor/loop/control.py:set_parked` then, not now.
- **No `fleet requeue`.** Answering a parked task means editing `[HUMAN]` back
  to `[ ]` in a tracker the human is already reading to answer the question.
  One character, in an editor that is already open.
- **No fleet-level singleton.** Two overlapping cycles are survivable — the
  per-checkout lock (T3.1) makes the second skip every busy repo. harbor's
  `runner.cycle_running()` pgrep probe is not ported.
- **No third run pass, ever.** Two passes bound the cycle (T3.4); a plan turn
  only ADDS tasks, so a third finds nothing a second could not.
