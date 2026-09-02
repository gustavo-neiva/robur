# Learnings

> Append-only guardrails the agent discovers while working on this repo.
> Read this before each turn; add new gotchas you hit (one bullet per line).
> A planner turn prunes stale entries periodically. The loop never depends on
> this file — it is advisory memory, not state.

- _(example)_ `npm test` must run from the repo root; a nested cwd makes it red.
- `File.expand_path("../lib", file_path)` keeps the filename — always expand against `File.dirname` (cost a turn in T1.1).
- `parse_repo_conf` truncates `.ratchet.conf` values at the first `#`: a `VERIFY_CMD` containing Ruby interpolation like `#{...}` is silently cut in half and RED-locks the loop. That is why the gate uses `File.expand_path(f)` instead of interpolation. Never put a `#` in any `.ratchet.conf` value.
- `exe/robur` resolves `lib/` relative to its own path: a copy of the script outside the repo dies with `LoadError` before printing anything. Differential-harness mutants need a shadow tree with `lib/` beside the mutated script.
- Differential parity needs per-side path normalization, not just tmp-root: each side's RATCHET_HOME basename ("home-base"/"home-cand") and the repo path (now `<home>/repo`, shared basename) leak into stdout and `last-log`; the slug's 6-digit cksum of the abs path also differs per side and is normalized to `<slug>`.
- Baseline help prints a blank line between the usage body and the `Config:` line, and baseline log files can carry invalid UTF-8 — the harness scrubs before gsub or it raises ArgumentError.
- `exe/robur` resolves `lib/` beside itself, so a differential mutant must copy BOTH `exe/robur` and `lib/` into the shadow tree; mutating a lib copy while pointing candidate_cmd at the real exe silently tests the unmutated code.
