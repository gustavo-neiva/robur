<!-- class: MACHINE -->
# PLAN.md — Track B: ratchet bash → robur (Ruby)

> Tracker grammar: `[x]` open → `[ ]` → `[x]`. Tags `(trivial|normal|hard)`
> route the model tier; `serial` forbids parallel siblings.

**robur** is the Ruby replacement for the bash ratchet loop. It is a NEW sibling
repo. The working bash ratchet in `ratchet/` builds it and therefore cannot break
itself.

**Path convention — read this before running any command.** Paths starting
`ratchet/`, `atlas/`, `harbor/` or `robur/` are written **estate-relative**: they
name sibling directories under `~/Code/gustavo-neiva/`. Your working directory is
the `robur` repo, so reach a sibling with `../` — `ratchet/lib/tracker.sh` is
`../ratchet/lib/tracker.sh` from where you are, and the bash binary the
differential harness compares against is `../ratchet/bin/ratchet`. Paths with no
such prefix (`lib/`, `test/`, `exe/`) are relative to this repo. Sibling repos are
separate git repos, and `../ratchet` is READ-ONLY — read it freely, never write it.

**This plan must NOT touch:** `ratchet/` — read-only for the entire migration, no
task may edit a byte of it — nor `atlas/bin/`, nor `atlas/cycles.conf` except the
one HUMAN task that adds this repo to it.

**Sequencing:** both tracks are live in `atlas/cycles.conf` as of 2026-09-01 and
run concurrently — `harbor` first in the chain, then `robur`. They touch disjoint
repos and share no files, so neither blocks the other. Track A still ships first
at *cutover*: it closes a security hole and takes the shell out of the daily path,
and its cutover is signed off before Track B's.

**Behaviour-compatible, not code-compatible.** These formats are FROZEN — robur
reads and writes them byte-identically, in both directions, so a rollback after
cutover finds valid state:

- `.ratchet.conf` — allowlisted `KEY=value`, the 48-key allowlist, the
  `COOLDOWN_<PROVIDER>` prefix rule, quote stripping, numeric coercion
- `~/.ratchet/conf` — bash-sourced today; robur must consume the same file (T2.2)
- the `PLAN.md` task grammar exactly as documented at `ratchet/lib/tracker.sh:1-21`
- `.ratchet/` state: `stop_reason`, `loop-backoff`, `last_task.state`,
  `milestone.cur`, `conf.hash`, `last-log`, `fanout.state`
- `~/.ratchet/metrics.tsv` — the same 12 columns in the same order
- the CLI surface — same commands, same flags, same exit codes

**The `.ratchet` names stay.** robur is the product name; the on-disk contract
keeps its current filenames for the whole migration, because rollback depends on
both binaries reading the same state. Renaming state files is not in this plan.

**Stdlib only.** `JSON`, `Time`, `FileUtils`, `Open3`, `Net::HTTP`,
`OptionParser`, `Digest` cover the observed surface. Minitest is pre-approved.
Any other gem needs a one-line justification in the task and a HUMAN gate — see
`atlas/MIGRATION-CUTOVER.md`. **Plain Ruby: no Sorbet, no RBS, no Steep** —
measured 2.3× token cost (audit §4.2).

**Real OOP, small classes, DI at the boundaries.** Filesystem, clock, subprocess
and HTTP are injected, so tests never need a fake `$HOME`. Seams: `Config`,
`Plan`/`Task`, `ModelChain`, `Turn`, `Classifier`, `CommitGate`, `Observability`,
`Repo`, `Cli`.

**Fix by construction, do not port.** Three JSON-parsing strategies collapse to
one `JSON.parse`; three open-task counters, four default-branch detections and two
copies of the worktree-porcelain state machine collapse to one each; the
greedy-paren tag bug at `ratchet/lib/tracker.sh:145` gets a correct parser and a
regression test.

**Do NOT redesign features.** Same tiers, same fallback/cooldown/bench policy,
same commit-gate ordering, same classification taxonomy. Behaviour changes are a
later project.

---

## Selftest triage — what gets a Ruby equivalent and what does not

44 bash suites. Domain behaviour is re-expressed in Minitest; shell-mechanic pins
exist only to constrain a language robur does not use, and are deliberately
dropped with the reason recorded here. This table is the contract; a task may not
silently port a dropped suite.

| # | bash suite | verdict | reason |
|---|---|---|---|
| 0 | render (terminal functions) | port | domain: the PM header/bar/timing render |
| 1 | turn classification | port | domain: the outcome taxonomy |
| 2 | tracker tag extraction | port + extend | domain, plus the `:145` greedy-paren regression |
| 3 | milestone parsing | port | domain |
| 4 | contract parsing | port | domain: the 48-key allowlist |
| 5 | tier routing | port | domain |
| 6 | session sanitizer | port | domain: thinking-block stripping |
| 7 | agnosticism (no project knowledge) | port, rewritten | invariant is real; the grep targets Ruby source |
| 8 | end-to-end (fake-agent) | port | domain, and the differential harness subsumes it |
| 9 | doctor tier warning | port | domain |
| 10 | tier routing end-to-end | port | domain |
| 11 | builtin secret scan | port BEHAVIOUR only | patterns are domain; the BSD-vs-GNU grep pins are not — Ruby `Regexp` has no such split |
| 12 | --cheap + staged-changes warning | port | domain |
| 13 | ratchet plan turn | port | domain |
| 14 | stats (tier/model counts) | port, re-based | reads structured events, not regexes over prose |
| 15 | doctor mid-operation check | port | domain: rebase/MERGE_HEAD detection |
| 16 | status rendering + liveness | port | domain |
| 17 | FANOUT contract key | port | domain |
| 18 | models (chain ops, conf upsert) | port | domain |
| 19 | bounded reap (watchdog kill) | port BEHAVIOUR only | the kill/deadline contract is domain; the bash 3.2 `kill -0`/`$SECONDS` mechanism it pins does not exist in Ruby |
| 20 | model cost cache (models.dev join) | port | domain |
| 21 | model-select (MODEL_RANK slice) | port | domain |
| 22 | chain_for_tier override wire-in | port | domain |
| 23 | build_default_prompt from template | port | domain |
| 24 | RATCHET_LOOP advisory-only | DROP | greps bash source for `if`/`case`/`[` branches on an env var; the invariant is re-expressed as one Ruby test that the flag is only ever written, never read |
| 25 | AGENTS.md human-only | port | domain: template content |
| 26 | init AGENTS.md migration | port | domain |
| 27 | doctor protocol delivery | port | domain |
| 28 | notify_human | port | domain |
| 29 | wait_for_merge | port | domain |
| 30 | plan_is_ready | port | domain |
| 31 | auto-plan flow | port | domain |
| 32 | milestone branch lifecycle | port | domain |
| 33 | per-task session resume | port | domain |
| 34 | gate-status note each turn | port | domain |
| 35 | parallel stash guard | port | domain |
| 36 | fanout orchestrator | port | domain |
| 37 | fanout-clean worktree sweep | port | domain |
| 38 | metrics (`_turn_usage` + append) | port | domain: the responseId dedupe rule |
| 39 | loop metrics hooks | port | domain |
| 40 | human_block_brief | port | domain |
| 41 | autoplan tier + KTLO prompt | port | domain |
| 42 | metrics isolation (`RATCHET_HOME`) | port | domain: the fixture-pollution regression |
| 43 | `PR_SOFT_MAX_LINES` default drift | DROP | pins that a constant is declared once; a Ruby constant cannot drift between a call-site fallback and a default |
| 44a | no empty tracked files repo-wide | DROP | guards leaked bash test stubs (`bin/gh`, `err.txt`) written by PATH-stub suites robur does not have |
| 44b | PATH-drift guard proves itself | DROP | pure shell mechanic: suites leaking `PATH` into each other. Minitest processes are isolated and boundaries are injected |
| 44c | docs cover metrics observability | DROP | doc-drift guard for the bash README; re-author against robur's own docs when they exist, not as a port |
| 44d | selftest banner numbering | DROP | bookkeeping for hand-numbered `suite_start N` banners; Minitest names its own tests |

Eight suites are dropped outright and two more are ported as behaviour with their
shell mechanism discarded — matching the audit's count of ≥8 pins that exist
solely to constrain bash.

---

## M1 — Scaffold, fixtures, and the differential harness

The harness is the primary deliverable. Nothing is ported until it can prove a
port changed nothing.

- [x] T1.1 (trivial, serial) scaffold the repo
    do: `git init` this directory; create `exe/`, `lib/robur/`, `test/`, `test/differential/`, `test/fixtures/`; add `.gitignore` covering `.ratchet/`, `tmp/`, `*.log`; add `lib/robur.rb` requiring nothing yet and defining `module Robur; VERSION = "0.0.1"; end`; add `exe/robur` as an executable stub that resolves its own symlink chain to find `lib/` and prints usage. Make one commit.
    done: Given a clean checkout, When `ruby -Ilib -e 'require "robur"; puts Robur::VERSION'` runs, Then it prints `0.0.1`; When `exe/robur` is symlinked onto PATH from another directory and invoked, Then it still finds `lib/` and prints usage.
    files: .gitignore, lib/robur.rb, exe/robur
- [x] T1.2 (trivial, serial) the repo contract files
    do: `.ratchet.conf` and `.gitignore` were bootstrapped by hand — verify them, do not rewrite them. Add `AGENTS.md` describing what robur is, the stdlib-only rule, the no-Sorbet rule, and the frozen-format list — no loop mechanics, that travels in the harness prompt. Add `LEARNINGS.md` with the append-only header, seeded with this gotcha: `.ratchet.conf` values are truncated at the first `#` by `parse_repo_conf`, so a `VERIFY_CMD` containing Ruby string interpolation like a `#{...}` sequence is silently cut in half and RED-locks the loop. That is why the gate uses `File.expand_path(f)` and not interpolation. Never put a `#` in any `.ratchet.conf` value.
    done: Given the three files, When `ratchet doctor .` runs from the bash ratchet, Then it exits 0 and reports the conf parses, the tracker has open tasks, and the protocol is current; the `VERIFY_CMD` it echoes ends in `}'` and is not truncated.
    files: AGENTS.md, LEARNINGS.md
- [x] T1.3 (trivial, serial) the test entrypoint
    do: add `test/test_helper.rb` requiring `minitest/autorun` and putting `lib/` on the load path, plus one `test/smoke_test.rb` asserting `Robur::VERSION`. Confirm the `VERIFY_CMD` one-liner discovers and runs it with no bundler and no Rakefile.
    done: Given the two files, When `ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'` runs, Then it reports 1 run, 1 assertion, 0 failures and exits 0.
    files: test/test_helper.rb, test/smoke_test.rb
- [x] T1.4 (normal, serial) port the fixtures
    do: copy `ratchet/test/fixtures/` into `test/fixtures/` — `fake-agent`, `fixture-repo/` with its `PLAN.md`/`verify.sh`/`.gitignore`/`README.md`, `turn-usage/*.json`, and `logs/*.log`. Copy only; do not edit `ratchet/`. The `fake-agent` script must stay byte-identical so both binaries face the same stub, including its `RATCHET_LOOP`/`RATCHET_FANOUT` stderr echoes.
    done: Given the copy, When `diff -r ratchet/test/fixtures test/fixtures` runs, Then it reports no differences; When `fake-agent` is invoked in a copy of `fixture-repo`, Then it ticks the first `[ ]`, marks the next `[ ]`, and prints `STEP_COMPLETE`.
    files: test/fixtures/
- [x] T1.5 (hard, serial) the differential harness — core
    do: add `test/differential/harness.rb` with a `Scenario` (name, argv, fixture setup, env) and a `Runner` that, for one scenario, builds two pristine copies of the fixture repo, points `RATCHET_HOME` at two separate temp dirs, sets `AGENT_CMD` to the fake-agent, runs `ratchet/bin/ratchet ARGV` in one and `exe/robur ARGV` in the other, and captures stdout, stderr, exit code, every file under `.ratchet/`, `metrics.tsv`, `loop.log`, and `git log --format='%s'`. Normalization is an explicit, narrow substitution list — timestamps, temp paths, elapsed seconds, PIDs, commit shas — and nothing else, because a wide normalizer hides the regressions this exists to catch.
    done: Given a scenario running `--help`, When the runner executes it, Then it returns a diff report object listing zero differences; When a deliberate extra space is injected into robur's usage text, Then the report lists exactly one difference and names `stdout`.
    files: test/differential/harness.rb
- [x] T1.6 (hard, serial) the differential harness — one-command runner
    do: add `test/differential/run.rb` as the single entrypoint: `ruby test/differential/run.rb [--suite NAME]`. It loads scenario files from `test/differential/suites/`, runs each, prints one line per scenario (`ok` or the diffing surfaces), and ends with `N diffs across M scenarios`. Exit 0 only when N is 0. Seed `suites/milestone-1.rb` with the `--help`, unknown-flag, and `doctor` scenarios.
    done: Given the seeded suite, When `ruby test/differential/run.rb --suite milestone-1` runs, Then it prints one line per scenario and a final count, and its exit code is 0 if and only if that count is 0.
    files: test/differential/run.rb, test/differential/suites/milestone-1.rb
- [x] T1.7 (trivial, serial) M1 self-QA
    do: run both gates and record the harness invocation in `AGENTS.md` so a fresh agent finds it.
    done: `ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'` exits 0, AND `ruby test/differential/run.rb --suite milestone-1` reports `0 diffs`. PASS is both exit 0 and the literal string `0 diffs` in the harness output.
    files: AGENTS.md, LEARNINGS.md

## M2 — Config and the boundaries

- [x] T2.1 (normal) Sys — the injected boundaries
    do: add `lib/robur/sys.rb` defining four tiny collaborators with real default implementations and no interfaces beyond what is used: `Sys::Fs` (read, write, exist?, mkdir_p, glob), `Sys::Clock` (now, monotonic, sleep), `Sys::Proc` (capture, spawn-with-deadline via `Open3`), `Sys::Http` (get, post via `Net::HTTP`). Every other class takes a `sys:` keyword defaulting to the real one. No plugin registry, no factory — these exist so tests need no fake `$HOME`.
    done: Given a test double for `Sys::Clock`, When a class that sleeps is constructed with it, Then no real time passes and the recorded sleep durations are assertable.
    files: lib/robur/sys.rb, test/sys_test.rb
- [x] T2.2 (hard, serial) Config — both conf files, and the sourced-conf decision
    do: add `lib/robur/config.rb`. The repo `.ratchet.conf` is PARSED with the 48-key allowlist, the `COOLDOWN_<PROVIDER>` prefix rule, one layer of quote stripping and the numeric-key digit coercion — never evaluated, because the loop later `eval`s `VERIFY_CMD` and an agent can write repo files. The global `~/.ratchet/conf` is bash-sourced today and contains `export PATH="$ASDF_DATA_DIR/shims:$PATH"`, which needs shell expansion, so robur consumes it by running `bash -c 'env -0'` once for a baseline and once after sourcing the file, then taking the delta: exported variables become the environment handed to spawned turns, plain assignments become config values. Record this decision and its trust boundary in a comment and in `AGENTS.md`: the global conf is trusted exactly as much as it is today, the repo conf is never trusted.
    done: Given `ratchet/.ratchet.conf` and the real `~/.ratchet/conf`, When `Config.load` runs, Then every key resolves to the same value the bash `parse_repo_conf` plus source produces, asserted by comparing against `bash -c '. conf; declare -p'` output; Given a repo conf containing `NOTIFY_CMD=x` or any other non-allowlisted key, Then it is rejected with a doctor error and never assigned.
    files: lib/robur/config.rb, test/config_test.rb, AGENTS.md
- [x] T2.3 (normal) Config — precedence and defaults
    do: add the neutral built-in defaults from `ratchet/lib/common.sh` as one frozen constant hash, and implement the precedence chain CLI flags > repo conf > global conf > defaults. `VERIFY_CMD` defaults empty so a missing gate stays a loud warning. Declare each default exactly once; there are no inline fallbacks at call sites.
    done: Given a value set in all four layers, When `Config.load` runs, Then the CLI value wins; Given it set in three, Then the repo conf wins, and so on down; Given `PR_SOFT_MAX_LINES` unset everywhere, Then it is 400 and that literal appears exactly once in `lib/`.
    files: lib/robur/config.rb, test/config_test.rb
- [x] T2.4 (normal) conf_hash and the doctor tamper pin
    do: add `Config#conf_hash` producing the same SHA-256 hex `ratchet/lib/contract.sh:conf_hash` produces, and read/write `.ratchet/conf.hash` in the same one-line format.
    done: Given `ratchet/.ratchet.conf`, When `Config#conf_hash` runs, Then it equals `shasum -a 256 .ratchet.conf | awk '{print $1}'`; Given a `.ratchet/conf.hash` written by bash ratchet, Then robur reads it and reports no tampering.
    files: lib/robur/config.rb, test/config_test.rb
- [x] T2.5 (trivial, serial) M2 self-QA
    do: extend the differential suite to cover config resolution and run both gates.
    done: `ruby test/differential/run.rb --suite milestone-2` reports `0 diffs` across the conf-parsing scenarios — valid conf, unknown key, malformed line, quoted value, numeric coercion, per-provider cooldown — where the compared surface is `doctor` stdout and exit code. PASS is `0 diffs` plus a green unit run.
    files: test/differential/suites/milestone-2.rb, LEARNINGS.md

## M3 — The tracker grammar

- [x] T3.1 (hard, serial) Task — a correct tag and id parser
    do: add `lib/robur/task.rb` with `Task.parse(line, lineno)` returning status (`open`/`in_progress`/`done`), id, tags, and text. Support every id form: `T1.2`, `T5`, `A1`, `I3`, `N-slug`, and `?` for none. The tag parser must scan the FIRST parenthesised group only — `ratchet/lib/tracker.sh:145` uses `.*\((trivial|normal|hard)[,)]` whose leading `.*` is greedy, so a task whose own text contains a word like hard in parentheses re-tags the task. Recognise `serial` and `independent` as additional tags.
    done: Given `- [ ] T1.2 (normal, serial) rewrite the greedy matcher`, When parsed, Then id is `T1.2`, tags are `normal` and `serial`, status is open; Given a line tagged `(trivial)` whose title text later contains a parenthesised occurrence of the word hard, Then the tag is still `trivial` — this is the `:145` regression and it must be a named test.
    files: lib/robur/task.rb, test/task_test.rb
- [x] T3.2 (normal) Plan — the one open-task counter
    do: add `lib/robur/plan.rb` wrapping a tracker file: `next_task`, `open?`, `in_progress?`, `counts` (open, in-progress, done), `completed_list`, `completed_subject`, `task_block`, `class_marker`. `counts` is the single counter — bash has three implementations and `atlas/bin/board-update.sh:13` gets it wrong by omitting `[ ]`. Honour the heading skip rule: `[ ]` lines under a heading whose lowercased text matches `done` or `checklist` are not tasks.
    done: Given `ratchet/PLAN.md`, When `counts` runs, Then it matches `tracker_count_done` and the bash open-count for that file; Given a `[ ]` line under a `### Definition of Done` heading, Then `next_task` skips it and `open?` ignores it.
    files: lib/robur/plan.rb, test/plan_test.rb
- [x] T3.3 (normal) Plan — milestones and readiness
    do: add `milestones` (name, done, total per `## ` section), `current_milestone` (name, index, count, done, total for the section holding the first open task), `ready?` (no `_(...)_` placeholders outside backticks, at least one tagged open task, and an all-done tracker counts as ready), and `independent_milestones`.
    done: Given `ratchet/PLAN.md` and `ratchet/templates/PLAN.seed.md`, When each method runs, Then the outputs equal the bash `tracker_milestones`, `tracker_current_milestone`, `plan_is_ready` and `fanout_independent_milestones` results for the same files, asserted by executing both.
    files: lib/robur/plan.rb, test/plan_test.rb
- [x] T3.4 (normal) human_block_brief
    do: add `Plan#human_block_brief(id, title)` producing the Telegram DM body byte-identically to `ratchet/lib/tracker.sh:human_block_brief` — the title line, the 900-char task block, the unblock instruction naming the tracker path, and the `/blocked` pointer.
    done: Given the fixture repo and a known task id, When the brief is produced by both implementations, Then the two strings are identical including the 900-char bound and the fallback text when the block is not found.
    files: lib/robur/plan.rb, test/plan_test.rb
- [x] T3.5 (trivial, serial) M3 self-QA
    do: add the tracker scenarios to the differential suite and run both gates.
    done: `ruby test/differential/run.rb --suite milestone-3` reports `0 diffs` across all fixture repos, where each scenario runs `status` and `once` against a tracker variant — tagged, untagged, `[ ]`, all-done, placeholder-seeded, and the greedy-paren case — and compares stdout, exit code and the resulting `PLAN.md`. PASS is the literal `0 diffs`.
    files: test/differential/suites/milestone-3.rb, LEARNINGS.md

## M4 — Models, turns, classification

- [x] T4.1 (normal) ModelChain — first-available, bench, cooldown
    do: add `lib/robur/model_chain.rb` holding the chain, the per-model transient strike counts and bench-until timestamps, with `pick`, `bench!`, `strike!`, `reset_all`, and the per-provider `COOLDOWN_<PROVIDER>` override resolved from the model's leading path segment. Take `Sys::Clock` by injection so cooldown expiry is testable without sleeping.
    done: Given a three-model chain, When the first is benched, Then `pick` returns the second; When all are benched, Then `pick` returns nil; When the injected clock advances past the cooldown, Then the first is picked again; Given `COOLDOWN_ZAI=3600` and a global `COOLDOWN=14400`, Then a `zai/...` model unbenches after 3600 simulated seconds.
    files: lib/robur/model_chain.rb, test/model_chain_test.rb
- [x] T4.2 (normal) tier selection
    do: add `lib/robur/tier.rb` resolving a task tag to a tier (`trivial`→light, `hard`→build-hard, else build), the chain for a tier with the documented fallback order, the thinking level per tier, `AUTOPLAN` falling back to `PLAN` then flat, and the `--cheap` override that forces every tier to light. Include the `MODEL_RANK` auto-slice for unset tiers.
    done: Given each combination of set and unset tier keys from the bash suite-5, suite-21 and suite-22 cases, When the tier chain is resolved, Then it equals what `chain_for_tier` returns for the same conf, asserted against recorded bash output.
    files: lib/robur/tier.rb, test/tier_test.rb
- [x] T4.3 (hard) Turn — one agent invocation with a watchdog
    do: add `lib/robur/turn.rb` running one `AGENT_CMD` invocation through `Sys::Proc`, streaming output to the turn file, enforcing `TURN_TIMEOUT` and the `STALL_TIMEOUT` no-growth kill, and recording the kill reason. Use `Process.wait` and a monotonic clock; the bash version hand-rolls this with `kill -0` and `$SECONDS` because bash 3.2 has no `timeout`.
    done: Given a stub agent that sleeps past the deadline, When the turn runs, Then it is killed, the kill reason is `deadline`, and the elapsed time is within one poll interval of the cap; Given a stub that emits nothing for longer than `STALL_TIMEOUT` then would finish, Then it is killed with reason `stall`; Given a stub that finishes normally, Then the exit code and captured output are intact.
    files: lib/robur/turn.rb, test/turn_test.rb
- [x] T4.4 (hard) Classifier — one JSON parser
    do: add `lib/robur/classifier.rb` returning `done | human | step | exhausted | hard | timeout | transient` in that precedence order. It parses the pi event stream with a single `JSON.parse` per line — bash parses this stream three ways in three files, by regex, by `jq`, and by an embedded Python heredoc. Token matches count only in assistant `text_end` events; error scans must exclude assistant `text`/`thinking` events, or a task that merely discusses a rate limit false-fires as exhausted.
    done: Given the `turn-usage` fixtures and recorded provider error bodies, When each is classified, Then the verdict matches bash `classify_turn` for every case in suite 1; Given an output whose assistant prose contains the phrase for a quota error, Then the class is not exhausted; Given a non-JSON plain-text output, Then classification falls back to literal token matching.
    files: lib/robur/classifier.rb, test/classifier_test.rb
- [x] T4.5 (normal) session sanitize
    do: add `lib/robur/session_sanitize.rb` stripping prior thinking blocks so any provider can continue a session, matching `ratchet/lib/session-sanitize.sh` behaviour, including the no-op path when `SANITIZE_THINKING=0`.
    done: Given the recorded session fixtures from bash suite 6, When sanitized, Then the output is byte-identical to the bash result; Given `SANITIZE_THINKING=0`, Then the input is returned unchanged.
    files: lib/robur/session_sanitize.rb, test/session_sanitize_test.rb
- [x] T4.6 (trivial, serial) M4 self-QA
    do: extend the differential suite with turn-level scenarios and run both gates.
    done: `ruby test/differential/run.rb --suite milestone-4` reports `0 diffs`, where the scenarios run `once` against the fixture repo with a stub agent forced into each outcome — step, done, human, exhausted, hard, timeout, transient — and compare stdout, exit code, `.ratchet/last_task.state` and the metrics row. PASS is the literal `0 diffs`.
    files: test/differential/suites/milestone-4.rb, LEARNINGS.md

## M5 — Repo, commit gate, observability

- [x] T5.1 (normal) Repo — one default-branch detection, one worktree state machine
    do: add `lib/robur/repo.rb` wrapping git through `Sys::Proc`: `default_branch` (one implementation; bash has four copies of the `symbolic-ref` plus `main` fallback), `status_porcelain`, `staged_diff`, `staged_files`, `commit`, `checkout_b`, `push`, `shortstat`, and `worktrees` returning parsed porcelain records (path, head, branch, detached) — one implementation replacing the two copies of the porcelain state machine in `ratchet/lib/commands.sh`.
    done: Given a fixture repo with an `origin/HEAD` ref and one without, When `default_branch` runs, Then it returns the ref's branch and `main` respectively; Given a repo with two added worktrees, When `worktrees` runs, Then it returns three records with correct paths and branches, and the primary is first.
    files: lib/robur/repo.rb, test/repo_test.rb
- [x] T5.2 (hard) CommitGate — same ordering, same blocks
    do: add `lib/robur/commit_gate.rb` preserving the exact bash ordering: stage all, un-stage `COMMIT_EXCLUDE_GLOBS` and `.ratchet.conf`, secret-scan the staged diff, run `VERIFY_CMD` as a hard gate, skip cleanly when nothing is staged, then one commit with the tracker-mined subject. The scan looks only at ADDED lines, honours the `ratchet:allow-secret` inline marker, and an empty added-line set is CLEAN — the inverted return there once dead-locked the loop. An empty `VERIFY_CMD` is a loud warning, never a silent skip.
    done: Given a green tree, When the gate runs, Then exactly one commit lands with subject `auto(ratchet): turn N MODEL — SUBJECT`; Given a red `VERIFY_CMD`, Then nothing is committed and the work is left staged; Given a staged private key, an AWS id, an `sk-` key, a JWT and a `.env` addition, Then each is blocked with the matching reason; Given a staged diff with zero added lines, Then the scan reports clean and the commit proceeds.
    files: lib/robur/commit_gate.rb, test/commit_gate_test.rb
- [x] T5.3 (hard, serial) Observability — structured events as the source of truth
    do: add `lib/robur/observability.rb` with an `Event` record and an `emit` that appends one JSON line to `events.jsonl` AND renders the frozen human line into `loop.log`. The log becomes a rendering of the events, killing the write-prose-then-regex-parse-it-back round-trip: bash writes English prose and parses it back with 5 regexes and 9 exact-wording substring checks, so rewording a log line silently zeroes a metric. The human-readable line format does not change.
    done: Given a run producing turn-start, turn-end, commit, bench and stop events, When the run finishes, Then `loop.log` is byte-identical to what bash ratchet writes for the same run, AND `events.jsonl` has one parseable record per line whose fields reconstruct that log line exactly.
    files: lib/robur/observability.rb, test/observability_test.rb
- [ ] T5.4 (normal) metrics.tsv and turn usage
    do: add `Observability#metrics_append` writing the same 12 tab-separated columns in the same order, defaulting to `RATCHET_HOME/metrics.tsv` and honouring `RATCHET_METRICS` — never `$HOME` directly, because hardcoding it made 333 of 340 recorded rows fixture noise. Add `turn_usage` summing per-message usage deltas deduped by `id`, `message.id`, `message.responseId` or `responseId` — zai streams carry no `id` and repeat the same usage 3–6 times per message.
    done: Given the `turn-usage` fixtures, When `turn_usage` runs, Then the in/out/cost triple equals the bash `_turn_usage` output exactly; Given `RATCHET_METRICS` pointed at a temp file, Then nothing is written to the real metrics file and the appended row has 12 fields in the frozen order.
    files: lib/robur/observability.rb, test/observability_test.rb
- [ ] T5.5 (normal) notify_human and stats
    do: add `notify_human` — emit `HUMAN NEEDED:`, ring the bell on a TTY, run `NOTIFY_CMD` in the background with the message as `$1`, and never accept `NOTIFY_CMD` from the repo conf. Add `stats` computing the baseline metrics from `events.jsonl` rather than by re-parsing prose, with a fallback that reads a legacy `loop.log` so old logs still report.
    done: Given a `NOTIFY_CMD` stub, When `notify_human` runs, Then the stub receives the message as its first argument exactly once; Given the `logs/*.log` fixtures, When `stats` runs on them, Then the printed metrics match `ratchet stats` on the same files line for line.
    files: lib/robur/observability.rb, test/observability_test.rb
- [ ] T5.6 (trivial, serial) M5 self-QA
    do: extend the differential suite to the gate and log surfaces and run both gates.
    done: `ruby test/differential/run.rb --suite milestone-5` reports `0 diffs`, where scenarios cover a green commit, a red gate, each secret-scan block, an idempotent turn, and a `.ratchet.conf` tamper attempt, comparing `loop.log`, the metrics row, and `git log --format='%s'`. PASS is the literal `0 diffs`, and the git-history comparison must include the commit subjects, not just the count.
    files: test/differential/suites/milestone-5.rb, LEARNINGS.md

## M6 — The CLI and the loop

- [ ] T6.1 (normal) Cli — argument parsing and exit codes
    do: add `lib/robur/cli.rb` using `OptionParser` for the full flag surface, plus the two-phase parse the bash entrypoint needs: a tolerant pre-scan that finds only the subcommand and repo dir so the repo conf can load before the authoritative parse. Preserve every exit code: 0 for a clean stop, 1 for preflight failure and PR-flow errors, 2 for the manual-merge and push-failure paths, and `die` for an unknown option.
    done: Given each documented flag and subcommand, When parsed, Then the resolved config matches the bash result; Given an unknown option, Then it exits non-zero with the same message shape; Given `--help`, Then stdout is byte-identical to `ratchet --help` after the program-name substitution.
    files: lib/robur/cli.rb, test/cli_test.rb
- [ ] T6.2 (hard, serial) the run loop
    do: add `lib/robur/loop.rb` orchestrating the turn cycle: the all-done fast path, tier routing with model reinit only on tier change, the tier-exhausted fallback to the flat chain, the all-benched backoff ladder 900/3600/14400, the per-outcome dispatch, the `ALL_DONE`-with-open-tasks downgrade to step, the timeout salvage that commits a green killed turn, the human-gate salvage, and the `MAX_DONE_GATE_FAILS` stop. Setting a status inside a branch must actually take effect — the bash version lost a status assignment inside a `case` arm and exited with open tasks.
    done: Given the fixture repo and the fake-agent, When `robur run` executes to completion, Then all three tasks are ticked, three commits exist, `.ratchet/stop_reason` is `done`, and the exit code is 0; Given a stub forced red for `MAX_DONE_GATE_FAILS` consecutive done-turns, Then the loop stops with `stop_reason` `gate_red` and notifies.
    files: lib/robur/loop.rb, test/loop_test.rb
- [ ] T6.3 (normal) state files
    do: add `lib/robur/state.rb` owning every `.ratchet/` file with the frozen formats: `stop_reason` (one word), `loop-backoff` (`count<TAB>until_epoch`), `last_task.state` (`taskid<TAB>status`), `milestone.cur` (`name<TAB>base_sha<TAB>cycle<TAB>errors`), `conf.hash`, `last-log`, `fanout.state`. Reads tolerate a missing file; writes never raise.
    done: Given each state file as written by bash ratchet, When robur reads it, Then the parsed value is correct; Given robur writes each one, Then bash ratchet's own readers — `stop_reason`, `backed_off`, `cut -f1 last_task.state` — return the same values, asserted by executing them.
    files: lib/robur/state.rb, test/state_test.rb
- [ ] T6.4 (normal) render and the status board
    do: add `lib/robur/render.rb` for the PM header, progress bar, timing and ETA lines, and `robur status` for the fleet board including liveness from the pid file and the milestone bars. Keep the ETA honestly labelled with the `~` prefix and `ETA unknown` before any recorded duration.
    done: Given the `logs/*.log` fixtures, When `robur status` renders, Then stdout is byte-identical to `ratchet status` on the same fixtures; Given no recorded turn duration, Then the ETA line reads `ETA unknown`.
    files: lib/robur/render.rb, test/render_test.rb
- [ ] T6.5 (hard) init, doctor, new, plan
    do: add `lib/robur/commands.rb` with `init` (stamp `.ratchet.conf`, `AGENTS.md`, seed `PLAN.md`, `LEARNINGS.md`, strip a legacy `ratchet-protocol:v1` block while preserving surrounding prose, write `conf.hash`), `doctor` (conf parses, tracker has work, tokens align, protocol current, mid-operation detection, tier warnings, conf-hash tamper), `new`, and `plan` with its `--auto` variant and the KTLO prompt for a caught-up tracker.
    done: Given a bare repo, When `robur init` runs, Then the stamped files are byte-identical to `ratchet init`'s output; Given a repo mid-rebase, a repo with a legacy protocol block, and a repo with `LIGHT_MODELS` but no `THINKING_LIGHT=off`, When `robur doctor` runs on each, Then stdout and exit code match `ratchet doctor` exactly.
    files: lib/robur/commands.rb, test/commands_test.rb
- [ ] T6.6 (hard) models, PR flow, fanout
    do: add `lib/robur/models_cmd.rb` (`list`/`add`/`remove`/`thinking`/`rank`, registry validation against the pi model cache, conf upsert, `--repo` targeting with a conf-hash re-stamp), and add the PR-cadence path to the loop — plan PR #0, milestone branch lifecycle, the bounded review turn, `open_milestone_pr`, and `wait_for_merge` with its four return states — plus `fanout` and `fanout-clean` using the single `Repo#worktrees` parser and the fail-toward-KEEP rule.
    done: Given the recorded `gh` stub responses from bash suites 29, 31, 32, 36 and 37, When each flow runs, Then the emitted log lines, the `milestone.cur` contents, the `fanout.state` contents and the exit codes match bash exactly, including that a worktree with a stash, an unpushed commit or a dirty tree is KEPT.
    files: lib/robur/models_cmd.rb, lib/robur/loop.rb, test/pr_flow_test.rb
- [ ] T6.7 (trivial, serial) M6 self-QA
    do: run the full differential suite across every command and both gates.
    done: `ruby test/differential/run.rb --suite milestone-6` reports `0 diffs` across every subcommand — `run`, `once`, `init`, `new`, `plan`, `plan --auto`, `doctor`, `status`, `stats`, `models`, `fanout`, `fanout-clean` — on all fixture repos. PASS is the literal `0 diffs`; a scenario that cannot be compared must be listed as unsupported in the report, never silently skipped.
    files: test/differential/suites/milestone-6.rb, LEARNINGS.md

## M7 — Parity gate, then rewiring

Software first. Every rewiring task below is deferred to the end on purpose: the
port must be provably identical before any live reference moves.

- [ ] T7.1 (hard, serial) the parity gate
    do: add `test/differential/suites/parity.rb` composing every milestone suite into one run, plus a long-run scenario driving the fixture repo from empty tracker to `ALL_DONE` across many turns with the fake-agent. `ruby test/differential/run.rb --suite parity` is the single command that proves feature parity.
    done: Given all fixture repos, When `ruby test/differential/run.rb --suite parity` runs, Then it reports `0 diffs` across every scenario in every milestone suite and exits 0; When any single milestone suite is failing, Then the parity run fails and names it.
    files: test/differential/suites/parity.rb
- [ ] T7.2 (trivial, serial) publish the parity evidence
    do: run the parity gate and paste its verbatim output, the date, and the robur git sha into the Track B evidence block of `atlas/MIGRATION-CUTOVER.md`. Do not perform any rewiring and do not tick any checklist box — that document is human-owned.
    done: Given a green parity run, When this task completes, Then `atlas/MIGRATION-CUTOVER.md` contains the verbatim output under `## Track B — parity evidence` with a date and a sha, and every checklist box in that document is still unticked.
    files: ../atlas/MIGRATION-CUTOVER.md
- [ ] T7.3 (normal, serial) the rewiring inventory
    do: produce `REWIRING.md` in this repo: every live reference to the bash ratchet that cutover must move, each with its file, line, current value, target value, and the exact revert. Cover at minimum the `ratchet` symlink on PATH, `atlas/cycles.conf` repo paths, `~/.ratchet/conf` `NOTIFY_CMD`, the launchd plist, `atlas/bin/money-loop.sh`'s `ratchet run` and `ratchet plan --auto` invocations, harbor's `/loop` and `/blocked` paths, and any `RATCHET_HOME` or `RATCHET_METRICS` override. Find them by grep, not from memory. Change nothing.
    done: Given the estate, When `REWIRING.md` is complete, Then every entry names a file and line that currently exists, each has a one-line revert, and re-running the same greps surfaces no reference absent from the document.
    files: REWIRING.md
- [ ] T7.4 (trivial, serial) M7 self-QA and Track B close
    do: final gate, then append the Track B close entry to `LEARNINGS.md`.
    done: `ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'` exits 0 AND `ruby test/differential/run.rb --suite parity` reports `0 diffs` AND `git -C ../ratchet status --porcelain` is empty, proving no task in this plan touched the read-only bash ratchet. PASS is all three.
    files: LEARNINGS.md

> **Cutover is not in this plan.** Executing the rewiring in `REWIRING.md` —
> swapping `cycles.conf` paths, `NOTIFY_CMD`, and the `ratchet` name on PATH — is
> `class: HUMAN` and lives in `atlas/MIGRATION-CUTOVER.md`, blocked on T7.1
> reporting `0 diffs`. Rollback is reverting that one config change.
