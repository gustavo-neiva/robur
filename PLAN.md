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

## Milestone 6 — reading the fleet without a browser

> The console is not ported. These three tasks are the replacement: text that
> answers the two questions an operator actually has — what is it doing, and
> what is waiting on me. All three are `(serial)`: they share `fleet.rb`,
> `cli.rb`, `render.rb` and `cycle.rb` with milestones 0-5.

- [x] T6.1 (normal, feat, serial) `robur fleet status` shows the whole fleet on one screen
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

- [x] T6.2 (normal, feat, serial) every cycle decision lands in events.jsonl, not just in prose
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

- [x] T6.3 (trivial, docs, serial) README and the conf example document the fleet as a first-class half
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
