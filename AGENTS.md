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

## Gates

Run both after any change:

    ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'   # unit gate: exit 0
    ruby test/differential/run.rb --suite milestone-1                                # diff gate: must print "0 diffs"

## Gotchas

- Never put a `#` in any `.ratchet.conf` value — `parse_repo_conf` truncates at
  the first `#`, so Ruby interpolation in `VERIFY_CMD` is silently cut in half
  and RED-locks the loop. The gate uses `File.expand_path(f)` for this reason.
