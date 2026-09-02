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
