<!-- class: MACHINE -->
# REWIRING.md — every live reference cutover must move

Produced by `PLAN.md` task T7.3 on **2026-09-03** against robur
`da091a3`. Every entry below was found by grep against the live estate, not
from memory; the exact commands are in [How this was found](#how-this-was-found)
so re-running them is the completeness check.

**This document changes nothing.** It is the inventory the human executes from
`atlas/MIGRATION-CUTOVER.md`. Executing it is `class: HUMAN`.

## The shape of the cutover

One symlink. That is the whole rewiring.

Every caller in the estate invokes the **command name `ratchet`**, never a path
into `ratchet/bin/`. Repointing `/usr/local/bin/ratchet` at `robur/exe/robur`
therefore moves all of them at once, and none of the callers are part of the
cutover. Everything else in this document is a **verify**, not an edit.

That holds only because the on-disk contract keeps its names: `.ratchet/`,
`.ratchet.conf`, `~/.ratchet/conf`, `~/.ratchet/metrics.tsv`. Renaming any of
them turns this one-line change into an estate-wide one and breaks rollback.

---

## 1. EDIT — the `ratchet` name on PATH

| | |
|---|---|
| **File** | `/usr/local/bin/ratchet` (symlink, owned `root:wheel`) |
| **Current** | `→ /Users/gustavo-neiva/Code/gustavo-neiva/ratchet/bin/ratchet` |
| **Target** | `→ /Users/gustavo-neiva/Code/gustavo-neiva/robur/exe/robur` |
| **Command** | `sudo ln -sfn /Users/gustavo-neiva/Code/gustavo-neiva/robur/exe/robur /usr/local/bin/ratchet` |
| **Revert** | `sudo ln -sfn /Users/gustavo-neiva/Code/gustavo-neiva/ratchet/bin/ratchet /usr/local/bin/ratchet` |

Needs `sudo` — the link is root-owned. Record the before-state first:
`ls -l "$(command -v ratchet)" > /tmp/ratchet-symlink.before.txt`.

`exe/robur` resolves its own symlink chain to find `lib/`, so being invoked
through `/usr/local/bin/ratchet` under a different name is supported by
construction. There is no `robur` name on PATH and this cutover does not add
one: adding it later is additive and not part of the rollback path.

**Ruby dependency.** The bash ratchet needed only bash 3.2; robur needs a Ruby
that can run the stdlib-only port (`ruby 3.4.2` today, via asdf shims). The
shims are already on the spawned-turn PATH — `~/.ratchet/conf:26` exports
`$ASDF_DATA_DIR/shims` — but launchd invokes `money-loop.sh` through
`/bin/bash` with launchd's own PATH, so **confirm `ratchet --version` works
from a non-interactive shell** before signing off. This is the one new runtime
dependency the cutover introduces.

## 2. VERIFY ONLY — `atlas/cycles.conf`

| | |
|---|---|
| **File** | `atlas/cycles.conf:27` (`#…/ratchet`, parked), `:29` (`…/robur`, live) |
| **Current** | `robur` is already in the chain and running as a Track B build repo |
| **Target** | unchanged |
| **Revert** | n/a — nothing edited |

These are **repo paths the loop drives**, not paths to the loop binary, so the
cutover does not touch them. Two decisions are the human's, and both are already
staged in `MIGRATION-CUTOVER.md`:

- `:27` `#…/ratchet` — unpark only after Track B sign-off, and only if the bash
  repo should keep receiving KTLO plan turns. Leaving it parked forever is a
  valid end state.
- `:29` `…/robur` — after cutover, robur is both the loop *and* a repo the loop
  drives. That is self-hosting and it works, but the first night it does so is
  the first time a `robur` turn can rewrite the binary executing it. `exe/robur`
  reads its libs at startup, and `money-loop.sh:45-46` documents the same
  hazard for itself, so this is survivable — but observe it deliberately.

## 3. VERIFY ONLY — `~/.ratchet/conf`

| | |
|---|---|
| **File** | `~/.ratchet/conf:34` |
| **Current** | `NOTIFY_CMD='/Users/gustavo-neiva/Code/gustavo-neiva/harbor/.venv/bin/harbor notify'` |
| **Target** | unchanged |
| **Revert** | `cp ~/.ratchet/conf.before ~/.ratchet/conf` (back it up first) |

An absolute path into harbor's venv, not into `ratchet/`. robur consumes this
file by bash-sourcing it exactly as bash does (`Config.load_global`, T2.2) and
passes `NOTIFY_CMD` through untouched.

**Do not add a trailing `"$1"`.** Both harnesses append the message themselves
(`sh -c "$NOTIFY_CMD \"$1\"" _ "$msg"` — bash `observability.sh:17`, robur
`Observability#notify_human`); adding one delivers the message twice and errors.
The conf comment at `:31-33` says so; this is the single most likely
hand-edit mistake during cutover.

Also at `:26`: `export PATH="$ASDF_DATA_DIR/shims:$PATH"` — load-bearing for the
Ruby dependency in §1, and consumed identically by robur.

## 4. VERIFY ONLY — the launchd job

| | |
|---|---|
| **File** | `~/Library/LaunchAgents/com.gustavo.money-loop.plist` |
| **Current** | `ProgramArguments` = `/usr/bin/caffeinate -i /bin/bash …/atlas/bin/money-loop.sh` |
| **Target** | unchanged |
| **Revert** | n/a — nothing edited |

The plist names `money-loop.sh`, never `ratchet`. It needs no edit and no
`launchctl` reload. Fires at 01:00, 07:00, 13:00, 19:00; logs to
`~/Library/Logs/money-loop.log`. `com.gustavo.atlas-weekly.plist` contains no
ratchet reference.

## 5. VERIFY ONLY — `atlas/bin/money-loop.sh`

| | |
|---|---|
| **File** | `atlas/bin/money-loop.sh:120` (`ratchet run "$repo"`), `:184` (`ratchet plan --auto "$repo"`) |
| **Current** | bare command name, resolved through PATH |
| **Target** | unchanged |
| **Revert** | n/a — nothing edited |

Both call the **name**, so §1 moves them. This is why the cutover is one line.

`money-loop.sh` also reads `.ratchet/` state directly — `loop-backoff` (`:62`,
`:70-71`, `:81`), `stop_reason` (`:99-100`), `plan-approved` (`:87`),
`.ratchet.conf` (`:91`). All frozen filenames robur writes byte-identically, so
none of it moves. Note `is_runnable()` at `:91` gates on `.ratchet.conf`
existing — unchanged by cutover.

`atlas/bin/morning-report.sh:34,36` greps the log for the literal strings
`ratchet run finished OK:` and `ERROR: ratchet run exited`. Those are emitted by
`money-loop.sh` (`:121`, `:130`), **not** by the loop binary, so they survive
cutover unchanged. Do not "fix" this wording to `robur` — it would silently
break the morning report's per-repo flags.

## 6. VERIFY ONLY — harbor

| | |
|---|---|
| **Files** | `harbor/harbor/interfaces/telegram.py:180, 187, 770`; `harbor/harbor/cli.py:709-715` |
| **Current** | reads `.ratchet/stop_reason`, `.ratchet/last_task.state`, `.ratchet/loop-backoff`, and `cycles.conf` |
| **Target** | unchanged |
| **Revert** | n/a — nothing edited |

**harbor needs no rewiring at all.** `/blocked` and the loop views are file
reads of frozen `.ratchet/` state (`telegram.py:167` says so explicitly), and
`harbor notify` is invoked *by* the loop through `NOTIFY_CMD`, never the other
way. harbor never invokes the `ratchet` binary and holds no path into
`ratchet/`.

Post-cutover checks: `/blocked` renders a human-blocked repo, and `:187`'s
`last_task.state` split on `\t` still yields the task id — robur writes the same
`<id>\t<class>\n`.

## 7. VERIFY ONLY — `RATCHET_HOME` / `RATCHET_METRICS`

Grepped across `atlas/`, `harbor/`, `~/.zshrc`, `~/.zprofile`, `~/.zshenv`,
`~/.ratchet/conf` and `~/Library/LaunchAgents/`: **no live override exists.**
Both resolve to their defaults (`~/.ratchet`, `~/.ratchet/metrics.tsv`). The
only uses are inside the two repos' own test suites, which isolate them per-run
and are not estate references. Nothing to move.

## 8. VERIFY ONLY — `~/.ratchet/metrics.tsv` column count

| | |
|---|---|
| **Consumers** | `atlas/bin/status.sh:47-48, 105`; `atlas/bin/morning-report.sh:48-56` |
| **Current** | bash writes 12 tab-separated columns on every row |
| **After cutover** | `run` rows stay 12; `turn` rows carry 15 |

robur appends three columns past the frozen 12 on turn rows — `fresh_in`,
`cache_read`, `messages` (`Observability::METRICS_EXTENSION_COLUMNS`). Columns
1-12 are unchanged in content and order, which is what `PLAN.md` freezes.

**Verified compatible, not assumed.** Both consumers parse positionally under
`awk -F'\t'` — `$2`, `$6`, `$10`, `$11`, `$12` — and neither uses `NF` or `$NF`,
so trailing columns are invisible to them. `status.sh:105` prints `$0` for the
last row, but it selects `$3=="run"` and run rows stay at 12 columns, so even
that display is byte-identical. The bash `metrics_append`
(`ratchet/lib/observability.sh:239`) writes a fixed 12-field `printf` and reads
the file never, so rollback mid-week onto a file containing 15-column rows is
safe in both directions.

⚠️ **One line in `MIGRATION-CUTOVER.md` is now stale because of this.** Its
"After" checklist reads *"`~/.ratchet/metrics.tsv` gains rows with 12 fields in
the frozen order"*. As written that check fails on a robur turn row. It should
read: *"turn rows carry the 12 frozen fields in order (plus 3 appended
robur-only columns); run rows carry exactly 12."* That document is human-owned
and T7.2 forbids editing it, so **this is flagged for the human, not fixed
here.**

---

## How this was found

Re-run these; anything they surface that is not in this document is a gap.

```
ls -l "$(command -v ratchet)"
cat atlas/cycles.conf
grep -n 'NOTIFY_CMD\|ratchet\|PATH' ~/.ratchet/conf
grep -rn 'ratchet' ~/Library/LaunchAgents/*.plist
grep -n 'ratchet run\|ratchet plan\|ratchet doctor\|ratchet init' atlas/bin/*.sh
grep -rl 'ratchet' harbor --exclude-dir=.git --exclude-dir=.venv
grep -rn 'RATCHET_HOME\|RATCHET_METRICS' atlas harbor ~/.zshrc ~/.zprofile ~/.zshenv ~/.ratchet/conf ~/Library/LaunchAgents
grep -rn "metrics" atlas/bin/*.sh
```

Two greps deliberately return nothing, and that is the finding: no
`RATCHET_HOME`/`RATCHET_METRICS` override exists anywhere live (§7), and no
caller anywhere holds a filesystem path into `ratchet/bin/` (§1 — every one uses
the bare command name).

## Summary

| # | Reference | Action |
|---|---|---|
| 1 | `/usr/local/bin/ratchet` symlink | **EDIT** (the only one) |
| 2 | `atlas/cycles.conf:27,29` | verify — human decision on unparking |
| 3 | `~/.ratchet/conf:34` `NOTIFY_CMD` | verify — no trailing `"$1"` |
| 4 | `com.gustavo.money-loop.plist` | verify — no edit, no reload |
| 5 | `atlas/bin/money-loop.sh:120,184` | verify — moved by §1 |
| 6 | harbor `.ratchet/` state reads | verify — no rewiring needed |
| 7 | `RATCHET_HOME` / `RATCHET_METRICS` | verify — no live override exists |
| 8 | `metrics.tsv` column count | verify — ⚠️ stale checklist line |

**One edit, seven verifies.** Rollback is reverting the §1 symlink.
