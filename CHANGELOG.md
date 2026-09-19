# Changelog

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
