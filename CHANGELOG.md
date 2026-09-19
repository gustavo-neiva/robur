# Changelog

## Milestone 5 — perpetual, and loud when it cannot be
_2026-09-19 · 6 commits · +861/-25_

- [x] T5.1 `robur fleet --every 15m` keeps running and drains on Ctrl-C — `ff81458`
      Add `Fleet::Supervisor.new(interval:, cycle:, lifecycle:, clock:)` and `#run`: execute one cycle, sleep the interval, repeat.
- [x] T5.2 a dead-man ping proves the beat is alive, not just that it started — `06929f5`
      When `HEALTHCHECK_URL` is set in the global conf or ENV, ping `<url>/start` FIRST thing in `Cycle#run`, then close the pair at the end: the bare URL on a green cycle, `<url>/fail` on a red one.
- [x] T5.3 a repo blocked on a human nudges daily, not every beat and not once ever — `506113e`
      Add `Fleet::Notifier.new(clock:)` with `#notify_once(repo, key, msg)`: send unless `State.state_path(repo, "last_notified")` already holds `key` AND its mtime is newer than `RENOTIFY_SECS` (86400); write the marker either way.
- [x] T5.4 a fleet paused long enough to be forgotten says so — `c177b32`
      When the pause flag is older than `PAUSE_REMINDER_DAYS` (7), notify once a day through T5.3's `Notifier` naming how long it has been paused, then carry on skipping the cycle.
- [x] T5.5 the supervisor restarts itself after a turn rewrites its own code — `69cd404`
      A long-lived `--every` supervisor holds robur's code in memory, so the moment a turn commits to robur's OWN checkout the fleet keeps running the old `Fleet::*` forever — it cannot pick up the fix it just wrote.

Also in this range:
- `d7e1344` feat(robur): T6.1 `robur fleet status` shows the whole fleet on one screen

## Milestone 4 — the operator's knobs
_2026-09-19 · 2 commits · +99/-7_

- [x] T4.1 `robur fleet pause` and `resume` stop and restart the beat — `6b31617`
      Add `robur fleet pause` (create `Paths.fleet_paused_flag`) and `robur fleet resume` (unlink it, tolerating absence).
- [x] T4.2 `robur fleet retry` clears every backoff so a fixed fleet runs now — `d8ca9f0`
      Add `robur fleet retry`: for every active roster entry, call `Fleet::Backoff#clear!` and print how many were cleared.

## Milestone 3 — the cycle executes the plan
_2026-09-19 · 4 commits · +537/-23_

- [x] T3.1 one writer per checkout, and a busy repo is skipped not queued
      Add `Fleet::Lock.acquire(repo)` -> a `Lease` with `#release`, or `nil` immediately when the checkout is already locked.
- [x] T3.2 a child turn is spawned from the running ruby, never from $PATH — `5819b8a`
      Add `Fleet::Cycle.new(planner:, spawner:, lock: Fleet::Lock, out:)` and `#spawn(repo, *argv)` returning the child's exit status.
- [x] T3.3 a repo's stop reason decides its backoff, and a deliberate stop costs nothing — `e7296fc`
      Add `Cycle#record_outcome(repo, exit_status)` applying the policy table below, reading `Gate#stop_reason` after the child exits.
- [x] T3.4 `robur fleet` runs a real cycle and returns the cycle's status — `7d4c5e1`
      Add `Cycle#run` executing three phases in order: `cycle_plan[:runs]`, then `cycle_plan[:plans]` (`spawn(repo, "plan", "--auto", repo)`), then a SECOND run pass.
- [x] T3.5 the autoplan stamp is written only after a plan turn actually ran — `d3f008c`
      After a `:plan` decision spawns successfully, touch `State.state_path(repo, "autoplan.stamp")` so T2.2's per-repo rate limit advances.

## Milestone 2 — the planner decides a whole cycle, purely
_2026-09-19 · 4 commits · +628/-17_

- [x] T2.1 one pure planner produces the decisions both callers execute — `0f0ef8f`
      Add `Fleet::Planner.new(roster:, gate_for:, budget:, clock:, paused: false, already_ran: [])` where `gate_for` is a lambda `repo -> Fleet::Gate` (dependency injection, so the planner never touches disk) and `budget` is a Struct of `max_runs`, `max_plans`.
- [x] T2.2 a caught-up repo tops up its own backlog, but not on every beat — `ba77f15`
      A repo whose verdict is `:caught_up` and which has a tracker file is eligible for an unattended `robur plan --auto` turn.
- [x] T2.3 a paused fleet plans nothing and says so once — `1ba9ccb`
      When the planner is constructed with `paused: true`, `#decisions` returns a single `:skip` decision per active repo with reason `:paused`, and `#cycle_plan` returns empty run and plan phases.
- [x] T2.4 the fleet's budgets come from the human-owned conf, not from constants — `6d2d6a8`
      Nothing yet reads the seven global keys, so every budget in M1-M2 is a hardcoded default.

## Milestone 1 — every reason a repo does not run, in one verdict
_2026-09-19 · 3 commits · +137/-51_

- [x] T1.1 a failed repo backs off on a doubling ladder capped below a day
      Add `Fleet::Backoff.new(repo, base:, cap:, clock:)` over `Robur::State.read_loop_backoff` / `write_loop_backoff`, which already own the `count<TAB>until_epoch` format — do not parse that file here.
- [x] T1.2 a repo waiting on a human stops re-asking the same question
      Add `Gate#human_blocked?`.
- [x] T1.3 a class HUMAN plan waits for approval before it ever runs — `61ec7cb`
      Add `Gate#class_gated?`: true when the tracker's class marker is `HUMAN` and `Robur::State.state_path(repo, "plan-approved")` does not exist.
- [x] T1.4 Gate#verdict names one reason, and the dry run prints it — `aa2661f`
      Compose the checks into `Gate#verdict` -> a Symbol, evaluated in this fixed order so the reported reason is the most actionable one: `:no_conf` (not initialized), `:caught_up` (open_tasks == 0), `:backoff` (Backoff#active?), `:human_block` (human_blocked?), `:class_gate` (class_gated?), else `:runnable`.
- [x] T1.5 the gate is proven against a real repo layout, not a mock — `b709057`
      Add a fixture helper that builds a throwaway repo on disk — `.robur.conf`, a `PLAN.md` with a class marker and a mix of `[ ]`, `[IN PROGRESS]`, `[HUMAN]` and `[x]` lines, plus optional `.robur/stop_reason`, `.robur/last_task.state` and `.robur/loop-backoff` — and drive every `Gate` reader against it.

## Milestone 0 — the tracer bullet: one command answers "what happens next" (serial)
_2026-09-19 · 47 commits_

- [x] T0.1 the fleet namespace loads and the gate stays green — `93e4af1`
      Create the `Robur::Fleet` namespace module in `lib/robur/fleet.rb` (empty module body for now; later tasks add `Fleet.cycle` and `Fleet.dry_run`).
- [x] T0.2 the roster reads fleet.conf and keeps parked repos visible — `febcc2e`
      Add `Robur::Fleet::Roster`, the ONE parser of `fleet.conf` (one repo path per line, priority order, `#` comments).
- [x] T0.3 `robur fleet --dry-run` prints why each repo will or will not run — `96ab376`
      THE TRACER BULLET — thin, but end to end.

Also in this range:
- `d40f228` auto(robur): turn 4 zai/glm-5.3-flash — T0.4 (normal, serial) make Loop.run's epilogue run on every exit path
- `2564656` auto(robur): turn 5 zai/glm-5.3-flash — T1.1 (normal, serial) Turn.run ends the turn when an abort is requested
- `7539ec7` auto(robur): turn 6 zai/glm-5.3-flash — T1.2 (normal, serial) install Lifecycle in Loop.run and drain between turns
- `ebc2196` auto(robur): turn 7 zai/glm-5.3-flash — T1.3 (hard, serial) abort mid-turn without punishing the model
- `2a025ff` auto(robur): turn 8 zai/glm-5.3-flash — T1.4 (normal, serial) make every long wait interruptible
- `b1543ed` auto(robur): turn 9 zai/glm-5.3-flash — T1.5 (normal) add the `robur stop` command
- `1b3003f` auto(robur): turn 10 zai/glm-5.3-flash — T2.1 (normal, serial) flock loop.pid so two loops cannot share one tree
- `1451c8b` auto(robur): turn 11 zai/glm-5.3-flash — T2.2 (normal, serial) report leftovers from an unclean previous exit
- `02a07b4` auto(robur): turn 12 kimi-coding/kimi-for-coding — T2.2 (normal, serial) report leftovers from an unclean previous exit
- `3ba2cb9` auto(robur): turn 13 anthropic/claude-sonnet-5 — T2.3 (trivial) show the stop state in `robur status`
- `fccb285` auto(robur): turn 14 anthropic/claude-sonnet-5 — T3.1 (hard, serial) fanout drains its children instead of orphaning them
- `08239c9` auto(robur): turn 15 anthropic/claude-sonnet-5 — T3.2 (trivial) record the concurrency guarantees in AGENTS.md
- `99de982` auto(robur): turn 17 zai/glm-5.3-flash — T4.1 (normal) structured lifecycle events
- `a5a52bc` auto(robur): turn 18 zai/glm-5.3-flash — T4.2 (trivial) document the stop contract for operators
- `a33a868` fix(encoding): pin default_internal too, add a real subprocess regression test
- `ee0dfcc` fix(observability): stamp every event with a run_id, downstream ingest can't tell runs apart otherwise
- `53f04b2` fix(cli): give `robur once` the same crash-proof epilogue as Loop.run
- `c10dc01` fix(loop): act on runaway turns and add a per-task attempt ceiling reset_all cannot clear
- `7805582` fix(loop): name quota-killed partial work in last_turn.note so the next turn continues it
- `56837c9` fix(observability): ignore message_update stream chunks in turn_usage_detail
- `966218b` fix(notify): the human-attention channel had never once delivered
- `d5c4ac7` docs: add README and MIT license
- `5f2cfae` docs: drop predecessor mention from README
- `3ffebe8` feat(loop): carpark HUMAN_PARKED tasks instead of stopping the repo
- `2beb869` test: drop bash/ratchet parity oracles; decouple robur from outer loops
- `324b55d` feat(changelog): finished milestones move themselves out of the tracker
- `38442d7` fix(robur): bound commit gate execution
- `573b696` plan(robur): refresh PLAN.lifecycle.md
- `ad6c279` plan(robur): M10 — classifier stops benching models for reading "quota"
- `7e1b9f6` plan(robur): refresh PLAN.md
- `2198968` fix(robur): park_question reads assistant text, not the echoed prompt
- `c1a0f1c` create fleet plan
- `5d8bc38` fix(robur): reliability-audit hardening across loop, turn and tests
- `7177f81` test: plan tests read a fixture tracker, not this repo's live PLAN.md
- `b767d99` refactor(robur): comment audit + dead-code sweep across lib
- `fd20d3a` fix(doctor): stop human-task lint flagging tasks about human gating
- `8bc91d4` chore(robur): T0.1 the fleet namespace loads and the gate stays green
- `ad14749` feat(fleet): Roster parses fleet.conf, keeps parked repos visible
- `10e9378` chore(plan): T0.2 done
- `17c1963` feat(fleet): T0.3 --dry-run prints why each repo will or will not run
- `2050e1f` chore(plan): T0.3 done
- `5a2d793` feat(fleet): T1.1 Backoff doubles failures on a ladder capped below a day
- `5639be8` chore(plan): T1.1 done
- `758dcd6` feat(robur): T1.2 a repo waiting on a human stops re-asking the same question
