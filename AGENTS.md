# robur

An autonomous coding loop: it reads a tracker, runs one ephemeral agent turn per
task against a green gate, commits only what passes, and routes each task to a
model tier by cost. Ruby, stdlib only.

The on-disk formats are a contract other tools read (`atlas`, `harbor`) — the
tracker line grammar, the `.robur.conf` allowlist, the session/journal file
formats, the `STEP_COMPLETE`/`ALL_DONE` tokens and the metrics columns. PLAN.md
is where they are pinned; changing one is a coordination problem, not an edit.

## Rules

- **Stdlib only.** Ruby standard library. No gems, no Bundler, no Gemfile.
- **No Sorbet.** No type annotations, no sig blocks.
- **No loop mechanics here.** The loop protocol travels in the harness prompt;
  this file is for human-led sessions only.
- **Never hardcode an on-disk name.** `.robur/`, `.robur.conf`, `~/.robur/`,
  `ROBUR_HOME`, `ROBUR_METRICS`, `ROBUR_LOOP` all come from `Robur::Paths` and
  nowhere else. That module is also what keeps the legacy `.ratchet*` names
  resolving on read and leaves `.ratchet` as a symlink to `.robur` on write, so
  a repo that never migrates keeps working and external readers never notice.
- **`../ratchet` is read-only.** Never write a byte there.

## What to read

- **PLAN.md**: task roadmap (tracker grammar is documented at the top).
- **LEARNINGS.md**: gotchas discovered while working here.

## Config trust boundary

- The repo `.robur.conf` (or a legacy `.ratchet.conf`) is **PARSED, never
  evaluated** (`Robur::Config.parse_repo`): allowlisted keys only, one layer of
  quote stripping, numeric coercion, truncate at the first `#`. Reason: the loop
  `eval`s `VERIFY_CMD` and an autonomous agent can write repo files — a sourced
  repo conf would let anything landing in the repo execute code outside any
  agent permission model. Non-allowlisted keys are doctor errors and are never
  assigned. `NOTIFY_CMD` in particular is rejected here for exactly this reason.
- The global `~/.robur/conf` is **trusted** (human-owned, not agent-writable)
  and is bash-sourced — it needs shell expansion
  (`export PATH="$ASDF_DATA_DIR/shims:$PATH"`). Robur consumes it by running one
  bash process that snapshots env + shell variables, sources the file, and
  snapshots again; the delta becomes: exported vars → the environment handed to
  spawned turns, plain assignments → config values (`Robur::Config.load_global`).

## Gate

One gate. Run it after any change; it must exit 0.

    ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'

## Gotchas

- Never put a `#` in any conf value — `parse_repo_conf` truncates at the first
  `#`, so Ruby interpolation in `VERIFY_CMD` is silently cut in half and
  RED-locks the loop. The gate uses `File.expand_path(f)` for this reason.
- `exe/robur` resolves `lib/` beside itself and must require every lib file a
  command touches. New module → add the require to `lib/robur/cli.rb` /
  `loop.rb` **and** `exe/robur`.

## Design decisions

Each of these is load-bearing and was paid for in production. Do not "simplify"
one back without reading why it exists.

- **Gate ordering**: staged-empty is checked BEFORE the secret scan and verify.
  Running a 36.5s verify suite on a turn that staged nothing is pure cost, and
  66% of production turns stage nothing.
- **`tin` definition**: metrics.tsv `tin` = input + cacheRead + cacheWrite —
  every prompt-side token, cache included. Anything that counts only `input`
  under-reports by 50-100×.
- **`:empty` turn class**: exit-0-with-no-output benches the model immediately
  and takes no strike. It is its own failure shape (1,574 production turns of
  it) and hiding it inside `:transient` made retries look healthy.
- **Real prompt (P0)**: `Prompt.for_turn` composes base + task block (≤40 lines)
  + `last_turn.note` + the RED verify tail. The task block is quoted IN the
  prompt — loop agents should not re-read the whole PLAN.md to find the current
  task.
- **Context profiles**: step turns spawn pi bare (`--no-skills
  --no-context-files`, ~10.6K vs 18.5K prompt-side tokens/turn, measured
  2026-09-04) — the quoted task block is the spec, the gate enforces repo
  conventions, and the prompt tells the agent to read AGENTS.md only when the
  task lacks that detail. Plan turns run full context+skills (PLAN.seed.md
  points the author at the plan-authoring skill); review keeps AGENTS.md
  (design decisions are the review criteria) but drops skills (personas are
  inlined in the template). If bare turns start red-gating on conventions, add
  a `ctx` tracker tag before ever making step turns full again.
- **ModelHealth**: ONE registry keyed by model id across all chains. Keying it
  by chain gave the same model two strike counters, which is the production
  infinite-spin. Includes hard-disable: 20 attempts, 0 wins → skipped forever,
  survives reset.
- **ProgressGuard**: 3/6/10/15 no-progress turns (no commit + no tracker mtime
  change) → bench model / inject context / block task / stop. `:block_task`
  rewrites the task as `[x] … — BLOCKED by progress guard`, because the frozen
  tracker grammar has no BLOCKED status to write.
- **Thinking clamp (C4)**: models matching `/(flash|turbo|highspeed|air)/` get
  THINKING_LIGHT (default `off`) unless the tier's THINKING_* key is explicit.
  Speed-tuned models spend a reasoning budget without earning it back.
- **Token-seen early kill**: `Turn.run` ends the turn once a step/done token
  appears, after a 0.2s reap-grace so the agent's own exit wins the race and the
  common case keeps a clean exit status instead of a timing-dependent 143.
- **events.jsonl**: structured telemetry written by `Observability`. The legacy
  loop.log regex adapter cannot see review verdicts, deadline-kill wall-hours or
  anything token-shaped, so a degraded source must name itself (`stats_source`)
  rather than silently substituting.
- **metrics.tsv columns 13-15**: turn rows carry three APPENDED columns —
  `fresh_in` (input + cache_write), `cache_read`, `messages` (agent
  round-trips). Columns 1-12 keep their content and order and run rows stay at
  12, which is what the format freezes for external consumers. Why: `tin` is
  cache-inclusive and therefore ~99.9% cache_read on a real turn (input=3,565 vs
  cache_read=2,555,904), so it cannot distinguish a bloated prompt from a cheap
  turn with many cached round-trips — the decomposition can. Verified safe for
  the two live consumers rather than assumed: `atlas/bin/status.sh` and
  `morning-report.sh` parse positionally under `awk -F'\t'` and never use `NF`.
  Set `usage:` to opt in; omit it and the row is the bare frozen 12.
- **Runaway round-trip warning**: turns at or above 200 deduped usage messages
  log a warning naming the count and the output tokens it bought. Healthy
  production turns measure 6; the observed pathology was ~1,100 round-trips and
  20M prompt-side tokens for 716 output ones. The threshold lives in ENV, not in
  the conf allowlist — that allowlist is a contract `doctor` rejects unknown keys
  against, so operational knobs never go in it.
- **MODEL_RANK**: tier chains plus flat `MODELS` already cover selection;
  `Tier.suggest_slice` cannot fire usefully until a cost/rank layer exists.
  Don't build the models.dev join.
- **Milestone advance** needs the external supervisor (atlas `money-loop.sh`) to
  restart `run` after a milestone PR merges. That is correct by design — the
  loop does not resurrect itself.
