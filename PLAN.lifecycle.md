<!-- class: MACHINE -->
# PLAN.lifecycle.md — robur: KTLO round 2

> Tracker grammar: `[ ]` open → `[IN PROGRESS]` → `[x]` done. Tags
> `(trivial|normal|hard)` route the model tier; a REQUIRED non-first kind
> `(feat|fix|perf|refactor|docs|test|chore)` becomes the commit prefix.
> `(serial)` forbids parallel siblings.

Sourced from: recent git history (29f0065, 5ffab48), LEARNINGS.md, and a
sweep for dependency debt (none — stdlib only, zero gems), flaky/skipped
tests (none beyond a legitimate machine-conf parity oracle), doc drift, and
dead code. Deliberately small: three tasks, no features.

## How to do ONE task here

1. Read only the files in `touches:`.
2. Find the anchor string given in `do:` — never a line number.
3. Make ONLY that change. No drive-by edits, no reformatting.
4. Add the test in `accept:` (one per Given/When/Then) to the named file,
   plain Minitest, `test/test_helper.rb` is the only helper.
5. Run `verify:` — it must exit 0.
6. Flip `- [ ]` to `- [x]` here. Print `STEP_COMPLETE`.

Repo rules for every task:

- **Ruby stdlib only.** No gems, no Bundler, no Gemfile, no Sorbet.
- **Never add a key to `Config::ALLOWLIST`** — frozen contract; knobs go in ENV.
- **Never hardcode an on-disk name** — `Robur::Paths` owns them all.
- **Never put a `#` in a `.robur.conf` value** — the parser truncates there.
- New file under `lib/robur/` → require it in BOTH `lib/robur/cli.rb` and
  `exe/robur`. (No task here creates one.)

---

## Milestone 1 — KTLO: test the deadline kill, delete the dead state API, align the docs

- [ ] T1.1 (normal, test) the commit-gate deadline kills the whole verify process group
      touches: test/commit_gate_test.rb
      do: Commit 29f0065 changed `Sys::Proc#spawn_with_deadline` to signal the
          NEGATIVE pid (process group) with TERM then KILL, because a plain
          `wait_thr.kill` orphans grandchildren — but every existing test
          stubs the method (`commit_gate_test.rb:213` spies on it), so the
          gate proves the escalation exists only by never running it. Add one
          REAL subprocess test: call
          `Robur::Sys::Proc.new.spawn_with_deadline(cmd, deadline: 1)` where
          cmd is a shell line that backgrounds a sleeping grandchild and then
          sleeps past the deadline itself, e.g.
          `sh -c 'sleep 30 & sleep 30'`. Given/When/Then: it returns within a
          few seconds (not 30) with a non-nil terminated status, and a
          `pgrep -f`-style check (capture `ps` output via Open3) shows NO
          surviving `sleep 30` process afterwards. This is the regression
          that matters: the whole point of the process-group kill is that
          nothing outlives a wedged VERIFY_CMD.
      accept:
          Given a verify command that spawns a grandchild and sleeps past the
          deadline
          When spawn_with_deadline runs with deadline: 1
          Then it returns in well under 30s with a killed/exited status, and
          no `sleep 30` process survives afterwards
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: test only, no lib changes; keep the runtime bounded
          (deadline 1, assert on elapsed or rely on the suite timeout); do not
          touch the spy-based tests

- [ ] T1.2 (trivial, chore) delete the loop-backoff State accessors nothing calls
      touches: lib/robur/state.rb, test/state_test.rb
      do: LEARNINGS.md records that `.robur/loop-backoff` is written ONLY by
          the external money-loop.sh — robur's
          `State.read_loop_backoff`/`State.write_loop_backoff`
          (`lib/robur/state.rb:41-52`) have zero callers in lib/ or exe/.
          Delete both methods, their `# loop-backoff:` comment, and the
          `test_loop_backoff_round_trip` test plus the `assert_nil
          Robur::State.read_loop_backoff(d)` line in `test/state_test.rb:13`.
          The on-disk format contract is unaffected: money-loop.sh reads and
          writes the file directly and never goes through Robur::State. If
          `tab_fields`/`write_tab_fields` still have callers
          (`read_last_task`/`write_last_task` do), keep the helpers; if a
          helper loses its last caller, delete it too.
      accept:
          Given the repo
          When grep finds read_loop_backoff or write_loop_backoff anywhere in
          lib/, exe/ or test/
          Then it finds nothing, and the gate stays green
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: pure deletion — no replacement, no deprecation shim; the
          `loop-backoff` FILE is not touched on disk, only the unused Ruby API

- [ ] T1.3 (trivial, docs) prune LEARNINGS.md references to the deleted archive and REWIRING files
      touches: LEARNINGS.md
      do: The header of LEARNINGS.md still says closed-milestone notes live in
          `LEARNINGS.archive.md` and that "Estate/cutover ops live in
          REWIRING.md" — both files were deleted from the repo (unstaged
          deletions in the worktree at plan time; confirm with `git status`
          and only proceed if they are still deleted). Rewrite the header
          sentences so the file stands alone: the prune instruction stays
          ("a planner turn prunes stale entries periodically"), the archive
          pointer goes, and the REWIRING pointer goes. Also scan the rest of
          LEARNINGS.md and the repo docs for other live references to either
          filename and fix those sentences the same way — delete the
          citation, keep the reason (this is the documented rule for
          provenance comments).
      accept:
          Given LEARNINGS.md and README.md and AGENTS.md
          When grep searches for "archive.md" and "REWIRING"
          Then no live reference to a nonexistent file remains, and the
          guidance those sentences carried (prune stale entries; estate ops
          are out of scope here) is still stated
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: documentation only, no code change; do not restore the
          deleted files; do not edit AGENTS.md content beyond removing a dead
          pointer if one exists there

## Definition of done

- All tasks `[x]`, VERIFY_CMD green.
- `grep -rn loop_backoff lib exe test` is empty.
- The gate runs a real deadline-kill test that would fail if a grandchild
  survived `spawn_with_deadline`.
- No doc points at a file that is not in the repo.

## Non-goals

- Any dependency work: the repo has zero gems by design.
- Touching the `config_test.rb` skip: it guards parity with the human-owned
  global conf and cannot be made hermetic.
- Deleting `State.read_stop`/`write_stop`/`clear_stop`: heavily used.
- Guard tests for the "exit code leaks from File.write-returning helpers"
  gotcha — enforcing a convention needs AST machinery the repo should not grow.
