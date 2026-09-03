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
