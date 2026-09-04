# robur

Ruby replacement for the bash ratchet loop (`../ratchet`, read-only sibling repo).
Behaviour-compatible with the bash ratchet, not code-compatible: the frozen
formats live in PLAN.md and must not change (tracker line grammar, `.ratchet.conf`
keys, session/journal file formats, tokens).

## Rules

- **Stdlib only.** Ruby standard library. No gems, no Bundler, no Gemfile.
- **No Sorbet.** No type annotations, no sig blocks.
- **No loop mechanics here.** The loop protocol travels in the harness prompt;
  this file is for human-led sessions only.

## What to read

- **PLAN.md**: task roadmap (tracker grammar is documented at the top).
- **LEARNINGS.md**: gotchas discovered while working here.

## Config trust boundary (T2.2)

- The repo `.ratchet.conf` is **PARSED, never evaluated** (`Robur::Config.parse_repo`):
  allowlisted keys only, one layer of quote stripping, numeric coercion, truncate at
  the first `#`. Reason: the loop `eval`s `VERIFY_CMD` and an autonomous agent can
  write repo files — a sourced repo conf would let anything landing in the repo
  execute code outside any agent permission model. Non-allowlisted keys are doctor
  errors and are never assigned.
- The global `~/.ratchet/conf` is **trusted exactly as much as it is today**
  (human-owned, not agent-writable) and is bash-sourced — it needs shell expansion
  (`export PATH="$ASDF_DATA_DIR/shims:$PATH"`). Robur consumes it by running one
  bash process that snapshots env + shell variables, sources the file, and
  snapshots again; the delta becomes: exported vars → the environment handed to
  spawned turns, plain assignments → config values (`Robur::Config.load_global`).

## Gates

Run both after any change:

    ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'   # unit gate: exit 0
    ruby test/differential/run.rb --suite milestone-1                                # diff gate: must print "0 diffs"

## Gotchas

- Never put a `#` in any `.ratchet.conf` value — `parse_repo_conf` truncates at
  the first `#`, so Ruby interpolation in `VERIFY_CMD` is silently cut in half
  and RED-locks the loop. The gate uses `File.expand_path(f)` for this reason.

## Deliberate divergences from bash (audit 2026-09-03 — all codified in `test/differential/`)

Do NOT "fix" these back to parity; each is load-bearing and paid for:

- **Gate ordering (E2a)**: staged-empty is checked BEFORE secret scan + verify
  (bash runs VERIFY_CMD even on no-op turns; this repo's is a 36.5s suite and
  66% of production turns stage nothing). Codified via `drop_lines:` on the
  affected scenarios with comments.
- **`tin` definition**: metrics.tsv `tin` = input + cacheRead + cacheWrite
  (total prompt-side tokens). Bash's number was 50-100× low; cache fields
  didn't exist when `_turn_usage` was written.
- **`:empty` class**: exit-0-no-output → bench immediately, no strike (1,574
  production turns of that shape hid inside `:transient`).
- **Real prompt (P0)**: `Prompt.for_turn` composes base + task block (≤40
  lines) + last_turn.note + RED verify tail. The literal `"turn"` prompt was
  the bug. Loop agents: the task block is quoted IN the prompt — don't
  re-read the whole PLAN.md to find the current task.
- **ModelHealth**: ONE registry keyed by model id across all chains (the
  chain-keyed state gave the same model two strike counters — the production
  infinite-spin). Includes hard-disable: 20 attempts, 0 wins → skipped
  forever, survives reset.
- **ProgressGuard**: 3/6/10/15 no-progress turns (no commit + no tracker
  mtime change) → bench model / inject context / block task / stop.
  `:block_task` rewrites the task `[x] … — BLOCKED by progress guard` (no
  BLOCKED status exists in the frozen grammar).
- **Thinking clamp (C4)**: models matching `/(flash|turbo|highspeed|air)/`
  get THINKING_LIGHT (default `off`) unless the tier's THINKING_* key is
  explicit.
- **Token-seen early kill**: `Turn.run` ends the turn once a step/done token
  appears (bash run-turn.sh:81), after a 0.2s reap-grace so the common case
  keeps a clean exit status.
- **events.jsonl**: robur-only structured telemetry (`Observability` is the
  log writer); excluded from differential snapshots by name.

- **metrics.tsv columns 13-15**: turn rows carry three APPENDED columns —
  `fresh_in` (input + cache_write), `cache_read`, `messages` (agent
  round-trips). Columns 1-12 are unchanged in content and order, run rows
  stay at 12, and the differential harness compares the first 12, so parity
  is still proved on exactly what the format freezes. Why: `tin` is
  cache-inclusive and therefore ~99.9% cache_read on a real turn
  (input=3,565 vs cache_read=2,555,904), so it cannot distinguish a bloated
  prompt from a cheap turn with many cached round-trips — the decomposition
  can. Verified safe for the two live consumers rather than assumed:
  `atlas/bin/status.sh` and `morning-report.sh` parse positionally under
  `awk -F'\t'` and never use `NF`. Set `usage:` to opt in; omit it and the
  row is the bare frozen 12.
- **Runaway round-trip warning**: turns at or above 200 deduped usage
  messages log a warning naming the count and the output tokens it bought.
  Healthy production turns measure 6; the observed pathology was ~1,100
  round-trips and 20M prompt-side tokens for 716 output ones. Threshold is
  `RATCHET_RUNAWAY_MESSAGES` in ENV, NOT a `.ratchet.conf` key — the conf
  allowlist is a frozen contract bash `doctor` rejects unknown keys against.
- **MODEL_RANK**: stale vs configured chains — tier chains + flat MODELS
  cover selection; `Tier.suggest_slice` can't fire usefully until a
  cost/rank layer exists. Don't build the models.dev join.
- **Milestone advance** needs the external supervisor (atlas money-loop.sh)
  to restart `run` after a milestone PR merges — correct by design.
