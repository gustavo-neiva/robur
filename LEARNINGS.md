# Learnings

> Append-only guardrails the agent discovers while working on this repo.
> Read this before each turn; add new gotchas you hit (one bullet per line).
> A planner turn prunes stale entries periodically (closed-milestone notes
> live in LEARNINGS.archive.md — don't re-read them every turn). The loop
> never depends on this file — it is advisory memory, not state.
> Scope: developing robur itself. Estate/cutover ops live in REWIRING.md;
> design rationale lives in AGENTS.md "Design decisions".

Frozen-format traps:
- `parse_repo_conf` truncates conf values at the first `#`: interpolation like `#{...}` is silently cut and RED-locks the loop. Never put a `#` in any `.robur.conf` value; that's why the gate uses `File.expand_path(f)`.
- `File.expand_path("../lib", file_path)` keeps the filename — always expand against `File.dirname`.
- `exe/robur` must require every lib file a command touches (it resolves `lib/` beside itself; a missing require once crashed doctor only when a conf existed). New module → add the require to `lib/robur/cli.rb`/`loop.rb` AND `exe/robur`.

Loop/turn mechanics:
- `Turn.run` must check `waitpid2` BEFORE the deadline every tick (a process finishing on the cap's tick is NOT a deadline kill), and must spawn with `chdir: dir` or multi-turn loops edit the wrong PLAN.md forever.
- `Plan#all_lines` may not be naively memoized (agent rewrites the tracker mid-run); the mtime+size stamp cache is the sanctioned fix — a same-tick same-size write is still missed (`# ponytail:` in plan.rb).
- `emit`/`term_only`/`flow` must honour `QUIET`, and `@quiet` is set from conf BEFORE the first emit; `once`'s preflight lines must land in loop.log too.
- Any `cmd_*`/helper whose last expression is a `File.write`/FileUtils call leaks its return value into the process exit code via `exit(CLI.run(ARGV) || 0)` — end command functions with an explicit `0`.
- Declaring ANY keyword param on a method that used to take a bare trailing hash breaks old callers (`ArgumentError`) — use `**opts` passthrough (cost: `Sys::Proc#capture`).
- Grep every caller of a method before moving it (moving `doctor_report` once broke `cmd_once`'s preflight silently).
- `MAX_DONE_GATE_FAILS` only accumulates when the tracker has ZERO tasks (not zero-open-with-done) — that's the only state reaching the `case :done` gate-fail branch.
- `Commands.plan_turn`/`Loop.run_review_turn` must export `ROBUR_LOOP`/`RATCHET_LOOP` for EVERY turn (build/plan/review alike) — the agent protocol reads it to know it is loop-driven.
- Test setup: `Loop.commit_review_injected_tasks` gates on a REAL `.git` dir even with an injected fake repo (mkdir it); `POLL_INTERVAL` of `0.1` in test conf cuts real-subprocess tests from ~3s to ~0.1s per test.

Tokens and telemetry:
- Prompt bloat is rarely where the cost is: `Prompt.for_turn` is base + a ≤40-line task block + note + verify tail, and nothing accumulates across turns (`--no-session`). Tokens burn inside the agent's own tool loop — only the round-trip count shows it. Measure before refactoring a prompt.
- `Turn.token_in?` must not re-read the whole turn file every poll tick that shows growth — quadratic on 1.8MB files at a 3s poll. Scan from `last_size`, rewound by `max_token - 1` so a token straddling a poll boundary is still seen; the rewind is the part that is easy to get wrong.
- In json mode a completion token counts ONLY inside an assistant `text_end` event (Classifier parity). `--mode json` streams the user-message echo live, and the prompt quotes the token names in its own instructions — a raw substring match TERM-killed every turn at the first poll and the loop read it as `:empty` on every model (2026-09-04 outage; the Classifier test suite already knew this, the watchdog didn't).
- Extending a frozen TSV: append past the last frozen column, keep the extension opt-in (`usage:`). Consumers parse positionally (`awk -F'\t'`, never `NF`) — a rollback onto a file with wider rows stays safe in both directions.
- Work in a `git worktree`, not a branch, when another session has the repo as its cwd. A branch switch moves HEAD for that session too; the supervisor can restart `robur run` at any time and would commit onto your branch.

Naming and the compat layer:
- Never hardcode an on-disk name — `Robur::Paths` is the single source (`.robur/`, `.robur.conf`, `~/.robur/`, `ROBUR_*`). The next rename should be a constant edit, not a 21-file sweep.
- The compat shape: READ the new name first with legacy fallback; WRITE the new name and leave the legacy path as a relative symlink. External readers follow the symlink and never notice. Cost: one symlink per path.
- A symlink only rescues a DIRECTORY; a plain file (`.ratchet.conf`) has no shim. And `Paths.link_legacy!` must refuse to replace a REAL `.ratchet` dir (the supervisor `mkdir -p`s it before writing backoff) — so "the symlink is always there" is NOT an invariant you can rely on.
- Home state on this machine: `~/.robur/` is the real dir, `~/.ratchet` is its symlink (migrated 2026-09-02). `Paths.home` order is `ROBUR_HOME` → `RATCHET_HOME` → `~/.robur` → `~/.ratchet`. Check what a resolver actually RETURNS before documenting a path as moved or unmoved — docs written from the design intent went stale the moment the migration ran.
- Provenance comments pointing at the retired bash repo are a liability: delete the citation, keep the reason, rewrite the sentence to stand alone. A justification that only survives as "a divergence from bash" was never a design decision, only a diff.
- The `.ratchet.conf` gap from the rebirth is closed: `robur init` installs the file shim itself (`Paths.ensure_repo_conf_link!` leaves `.ratchet.conf` -> `.robur.conf`), so a repo born on the new name satisfies `money-loop.sh`'s `is_runnable()` without being taught it. Don't re-flag it. Residual holes: a conf created by hand gets no shim until init runs, and the supervisor `mkdir -p "$repo/.ratchet"` leaves a repo on the legacy layout by design.
