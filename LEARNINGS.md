# Learnings

> Append-only guardrails the agent discovers while working on this repo.
> Read this before each turn; add new gotchas you hit (one bullet per line).
> A planner turn prunes stale entries periodically (closed-milestone notes
> live in LEARNINGS.archive.md — don't re-read them every turn). The loop
> never depends on this file — it is advisory memory, not state.

Frozen-format traps:
- `parse_repo_conf` truncates `.ratchet.conf` values at the first `#`: interpolation like `#{...}` is silently cut and RED-locks the loop. Never put a `#` in any `.ratchet.conf` value; that's why the gate uses `File.expand_path(f)`.
- `File.expand_path("../lib", file_path)` keeps the filename — always expand against `File.dirname`.
- `exe/robur` must require every lib file a command touches (it resolves `lib/` beside itself; a missing require once crashed doctor only when a `.ratchet.conf` existed). New module → add the require to `lib/robur/cli.rb`/`loop.rb` AND `exe/robur`.

Loop/turn mechanics:
- `Turn.run` must check `waitpid2` BEFORE the deadline every tick (a process finishing on the cap's tick is NOT a deadline kill), and must spawn with `chdir: dir` or multi-turn loops edit the wrong PLAN.md forever (bash `cd`s in main()).
- `Plan#all_lines` may not be naively memoized (agent rewrites the tracker mid-run); the mtime+size stamp cache is the sanctioned fix — a same-tick same-size write is still missed (`# ponytail:` in plan.rb).
- `emit`/`term_only`/`flow` must honour `QUIET`, and `@quiet` is set from conf BEFORE the first emit; bash's emit tees every line to loop.log once wired, so `once`'s preflight lines must land there too.
- Any `cmd_*`/helper whose last expression is a `File.write`/FileUtils call leaks its return value into the process exit code via `exit(CLI.run(ARGV) || 0)` — end command functions with an explicit `0`.
- Declaring ANY keyword param on a method that used to take a bare trailing hash breaks old callers (`ArgumentError`) — use `**opts` passthrough (cost: `Sys::Proc#capture`).
- Grep every caller of a method before moving it (moving `doctor_report` once broke `cmd_once`'s preflight silently).
- `MAX_DONE_GATE_FAILS` only accumulates when the tracker has ZERO tasks (not zero-open-with-done) — that's the only state reaching the `case :done` gate-fail branch.
- Test setup gotchas: `Loop.commit_review_injected_tasks` gates on a REAL `.git` dir even with an injected fake repo (mkdir it); `test/fixtures/fake-agent` is shared by BOTH differential sides; passing `"POLL_INTERVAL" => "0.1"` in test conf cuts real-subprocess tests from ~3s to ~0.1s per test.

Differential harness:
- Each side needs path normalization beyond the tmp root (home-base/home-cand, repo basename, the slug's 6-digit cksum → `<slug>`, pids → `<pid>`); group snapshot keys by normalized name or paired surfaces collide with nil.
- Baseline help has a blank line before `Config:`; baseline logs can carry invalid UTF-8 — scrub before gsub or it raises.
- Redirecting `HOME` breaks EVERY asdf shim, not just ruby — pin `ASDF_RUBY_VERSION` and `ASDF_PYTHON_VERSION` (and apply `asdf_env` to BOTH sides) or bash's `_turn_usage` python fallback silently swaps costs for `0`.
- `.ratchet.conf` stays untracked in scenarios (absolute per-side paths); it must be excluded from staging BEFORE the secret scan (the conf-tamper scenario proves it).
- `took=` wall-clock can tick a 1s boundary differently per side — blank the column when splitting metrics rows, don't digit-normalize.
- `Scenario#only` scopes a scenario to surfaces it actually contracts; use it (with a comment) for deliberate divergences — never weaken the normalizers.
- Known pre-existing divergence: `Config.load`'s global-conf lookup is hardcoded to `Dir.home` (real `$HOME`), not `RATCHET_HOME` (T2.2-era, out of scope).

Launch infrastructure (2026-09-03):
- NEVER put task prose with backticks/`\uXXXX` escapes inside a `workflowScript` template literal — one syntax error silently kills the whole fan-out. Launch each worker as its own plain-string async subagent call.
- Implementation workers launched with fork context died with empty responses (provider thinking-sanitization); launch workers with `context: "fresh"` and fully self-contained task text (they inherit nothing).
- Six workers on one glm quota can trip request-level 429s; a worker that dies <30s in wrote nothing — just revive it with the full task restated.

Audit-implementation session (2026-09-03):
- `Turn.run`'s token-seen kill races the agent's own exit: killing the moment the token flushes makes exitcode 143-vs-0 depend on poll timing (a harness flake). The 0.2s reap-grace (re-check `waitpid2` WNOHANG before TERM) makes the common case deterministic.
- Codifying a divergence: `Scenario#drop_lines: [Regexp]` drops matching LINES from file surfaces for that scenario only — every use must name the divergence and why in a comment; whole robur-only FILES are excluded by name in `snapshot_files` (events.jsonl).
- `Commands.plan_turn`/`Loop.run_review_turn` never exported `RATCHET_LOOP` (bash run-turn.sh:60 exports it for EVERY turn) — invisible until ../ratchet moved and the plan scenarios diffed; pre-existing at eeff1f8, not a regression.
- Shadow-tree probes need `exe/` + `lib/` + `templates/` siblings (exe resolves `../lib`; plan reads templates) or the probe dies with LoadError and looks like 5 new diffs.

Track B close — M7 done (2026-09-03):
- Final gate PASS, all three parts: unit suite `257 runs, 956 assertions, 0 failures` exit 0; `--suite parity` `0 diffs across 49 scenarios (1 unsupported)` exit 0; `git -C ../ratchet status --porcelain` empty — no task in this plan touched a byte of the read-only bash ratchet. Software is done; cutover is `class: HUMAN` and lives in `atlas/MIGRATION-CUTOVER.md` (evidence published there at atlas c1a78d8).
- The rewiring is ONE line. Every caller in the estate invokes the bare command name `ratchet`, never a path into `ratchet/bin/`, so repointing the `/usr/local/bin/ratchet` symlink moves all of them at once — `REWIRING.md` is 1 EDIT + 7 VERIFY-ONLY. This only holds because the on-disk `.ratchet*` names are frozen; renaming any of them turns cutover into an estate-wide change and breaks rollback.
- harbor needs NO rewiring: `/blocked` and the loop views are file reads of frozen `.ratchet/` state, and `harbor notify` is invoked BY the loop through `NOTIFY_CMD`, never the reverse. Confirm the direction of a dependency before inventorying it as one.
- Ruby is a NEW runtime dependency the bash loop did not have. launchd runs `money-loop.sh` via `/bin/bash` with launchd's PATH (not `.zshrc`, not the interactive shell), so `ratchet --version` must be confirmed from a non-interactive shell before sign-off. `~/.ratchet/conf:26` exports the asdf shims for spawned turns, but that is sourced by the loop, not by launchd starting it.
- `morning-report.sh` greps the log for the literal `ratchet run finished OK:` — those strings are emitted by `money-loop.sh`, NOT by the loop binary. Do not rename them to `robur` at cutover or the per-repo flags break silently while looking fine.
- Prose greps find callers; they do not prove compatibility. The metrics extension was only safe because `status.sh`/`morning-report.sh` parse positionally under `awk -F'\t'` (`$2/$6/$10/$11/$12`) and never use `NF` — that had to be read, not assumed. It also made one line of the human-owned cutover checklist stale (it expects 12-field rows); flagged there, not edited.

Token efficiency and observability (2026-09-03):
- `tin` cannot answer the question it exists for. It is `input + cache_read + cache_write`, and on a real turn that is ~99.9% cache_read (input=3,565, cache_read=2,555,904), so a $0.038 turn reads as 2.5M tokens. Always decompose: `fresh_in` (input + cache_write) is what moves when a prompt bloats; `cache_read` is nearly free. Keep them as separate columns — a sum that mixes them is unrecoverable after the fact.
- The runaway signal is ROUND-TRIPS, not tokens. Healthy turn: 6 deduped usage messages. Pathology: ~1,100 messages, 20,014,294 prompt-side tokens, 716 output tokens, then a timeout. `messages` was already computed and thrown away; token counts alone never made that turn look different from a big one.
- A silent fallback hides a dead telemetry path. No `events.jsonl` existed anywhere under `~/.ratchet/logs` — 244 directories, 2,227 turns — and nobody noticed because `stats` quietly dropped to the legacy loop.log regex adapter, which cannot see review verdicts, deadline-kill wall-hours or anything token-shaped. Degraded sources must name themselves (`stats_source`). The wiring was fine; only production traffic was bash. There is now a `Loop.run` test asserting the file lands.
- Prompt bloat was NOT where the cost was. `Prompt.for_turn` is base + a ≤40-line task block + note + a 30-line verify tail, with `--no-session`, so nothing accumulates across turns. The tokens are burned inside the agent's own tool loop, which only the round-trip count shows. Measure before refactoring a prompt.
- `Turn.token_in?` re-read the whole turn file every poll tick that showed growth — quadratic on 1.8MB files at a 3s poll. Scan from `last_size`, rewound by `max_token - 1` so a token straddling a poll boundary is still seen. Cheap fix, and the rewind is the part that is easy to get wrong.
- New tunables go in ENV, not `.ratchet.conf`: the allowlist is a frozen contract bash `doctor` rejects unknown keys against, so adding one there breaks parity. `SUMMARY_LINES`/`POLL_INTERVAL` set the precedent; `RATCHET_RUNAWAY_MESSAGES` follows it. Coerce a junk/zero override back to the default — `messages >= 0` would fire on every turn.
- Extending a frozen TSV: append past the last frozen column, keep the extension opt-in (`usage:`), and teach the differential harness to compare only the frozen prefix. Parity stays provable on exactly what the format freezes, and bash — which writes a fixed 12-field `printf` and reads the file never — is unaffected in both directions, so a mid-week rollback is safe.
- Work in a `git worktree`, not a branch, when another session has the repo as its cwd. A branch switch moves HEAD for that session too; the supervisor can restart `robur run` at any time and would commit onto your branch.
