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
- M1 self-QA (T1.7): both gates green — unit gate 4 runs / 9 assertions, 0 failures; diff gate `0 diffs across 3 scenarios` (help, unknown-flag, doctor). Harness invocation lives in AGENTS.md under Gates.
- `exe/robur` must require every lib file a command touches — `robur/config.rb` was missing, so doctor crashed with NameError only once a `.ratchet.conf` existed (M1's no-conf path never loaded it). New commands: add the require, or the differential suite is the only thing that catches it.
- Doctor conf-error parity has three separate surfaces: the leading blank indented line (bash errors string starts with `\n`), the `main()` stderr WARNING emitted with the RAW dir arg (`REPO_DIR` is not resolved until after the warning), and the VERIFY_CMD first-token executable check. Robur's `warn` maps to stderr; keep timestamps on the warning line only.
- Baseline allows `COOLDOWN_<PROVIDER>` but NOT `MODEL` — the allowlist key is `MODELS`. A suite scenario with an unallowlisted key silently turns "valid conf" into "unknown key".
