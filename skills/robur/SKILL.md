---
name: robur
description: Operate the robur autonomous coding loop — set a repo up, run it, watch it, and diagnose it when a run stalls, burns quota, or stops for a human. Use when the user asks how to run robur, wants a repo made loop-ready, is reading a loop.log or metrics.tsv, or says "the loop is stuck", "robur stopped", "why did it stop", "robur doctor", or "set up the loop".
---

# robur

robur runs a headless coding agent **one turn at a time** against a repo: it reads the next open task from a tracker, spawns an ephemeral turn, re-runs your test suite, and commits **only if the suite is green**. A red tree is never committed. It survives provider rate limits by falling back down a model chain, and routes each task to a cost tier.

This skill is for *operating* it. To author the `PLAN.md` it executes, use **robur-plan**.

## The mental model

Four things, and everything else follows:

1. **The tracker is the work queue.** `PLAN.md` — first `[ ]` or `[IN PROGRESS]` task is what runs next.
2. **The gate is the safety model.** `VERIFY_CMD` re-runs before every commit. No green, no commit; the work stays staged and the next turn is handed the failing output to repair.
3. **Turns are ephemeral.** `--no-session`: the agent has no memory between turns. The files are the memory.
4. **The loop stops on purpose.** `ALL_DONE`, a human-gate token, a red gate that will not clear, or a progress stall. `.robur/stop_reason` says which.

## Setting a repo up

```
robur init <repo>        # stamps .robur.conf, .robur/, AGENTS.md, seed PLAN.md, LEARNINGS.md
robur doctor <repo>      # preflight — MUST exit 0 before you run anything
```

`doctor` is the whole setup checklist in one command. It verifies the conf parses against the allowlist, the tracker has open work with resolvable task ids, `VERIFY_CMD` is set, the model chains are configured, and the repo is not mid-rebase. Read its output rather than guessing — every FAIL line names its own fix.

The two things that most often need a human after `init`:

- **`VERIFY_CMD` is empty.** `init` detects common stacks; if it cannot, it leaves the gate empty and says so loudly. An empty gate means *every* turn commits on the agent's word. Set it.
- **No models configured.** `robur models add <provider/id>` (global) or `--repo` (this repo only).

## Running it

```
robur run <repo>         # loop until ALL_DONE or a stop reason
robur once <repo>        # exactly one turn, then exit — use this first
robur run --cheap <repo> # force every tier to the LIGHT chain
```

**Always `robur once` before `robur run`** on a repo you have not driven before. One turn tells you whether the prompt, the gate and the model chain are all wired, for the cost of one turn.

## Watching it

```
tail -f "$ROBUR_HOME/logs/<slug>/loop.log"    # the loop's own narration
robur status <repo>                            # progress bars, current task, tier/model, ETA
robur watch <repo>                             # live pretty-printed agent output, 2nd terminal
robur stats <repo>                             # success rate, failure classes, wasted wall-hours
```

`$ROBUR_HOME` defaults to `~/.robur` (falling back to `~/.ratchet` if that is what exists). Per-run files live in `logs/<slug>/`: `loop.log`, `last_turn.out` (what the agent actually said), `last_verify.out` (why the gate went red), `events.jsonl` (structured telemetry), `last_turn.note`.

## Diagnosing — start here

**Always read `.robur/stop_reason` first.** It is one word and it tells you which of the following you are in.

| `stop_reason` | Meaning | What to do |
|---|---|---|
| `done` | Agent printed `ALL_DONE` and no open tasks remain | Nothing. Review the commits. |
| `gate_red` | `ALL_DONE` but the gate stayed red | Read `last_verify.out`. The work is staged, not lost. |
| `human_blocked` | Agent hit something needing a decision | Read the last `HUMAN NEEDED:` line in `loop.log`. |
| `progress_stalled` | 15 turns with no commit and no tracker change | The task is too big or impossible. Split it. |
| `review_exceeded` | Milestone review cycles exhausted | Read the review turn output. |

## Stopping a loop

`robur stop` writes `.robur/stop` and the running loop's `Lifecycle` reads it between polls. Four behaviours:

- **`robur stop` (drain)** — the loop finishes the current turn, commits if the gate is green, writes `stop_reason` `"stopped"` and exits 0. No new turn starts.
- **`robur stop --now`** — aborts the in-flight turn (the child agent is killed) but the loop still exits cleanly.
- **`robur stop --clear`** — deletes the stop file, cancelling a pending stop before the loop reads it.
- **Second Ctrl-C** — one INT/TERM raises the drain level; a second signal escalates a drain to an abort (same as `--now`).

### "The loop is stuck / spinning"

robur defines progress as *a commit or a tracker change*. Without either it escalates: **3** turns → bench the model and switch; **6** → inject a "change your approach" note; **10** → mark the task `[x] … — BLOCKED by progress guard` and advance; **15** → stop.

So a stuck loop is nearly always **one task that is too large or under-specified**. Check `robur status` for the current task, then split it in the tracker.

### "It burned a lot of quota"

`robur stats <repo>` gives the failure-class breakdown. Then read `~/.robur/metrics.tsv` — one row per turn, tab-separated:

```
1 date  2 repo  3 event  4 turn  5 tier  6 model  7 class  8 took  9 task
10 tok_in  11 tok_out  12 cost   13 fresh_in  14 cache_read  15 messages
```

Column 10 (`tok_in`) is **cache-inclusive** and is usually dominated by cache reads, so it is a bad cost signal on its own. Use:

- **13 `fresh_in`** — tokens actually paid for at full rate. This is what moves when a prompt bloats.
- **15 `messages`** — agent round-trips in that turn. **This is the runaway signal.** A healthy turn is single digits; a pathological one has hundreds and burns millions of prompt-side tokens for a few hundred output ones. Turns at or above 200 log a warning naming the count.

A quick per-model cost breakdown:

```
awk -F'\t' '$3=="turn"{n[$6]++; c[$6]+=$12} END{for(m in n) printf "%-34s %5d turns  $%.2f\n", m, n[m], c[m]}' ~/.robur/metrics.tsv
```

### "A model keeps failing"

Outcome classes: `step` / `done` (success), `exhausted` (quota — benched, no strike), `empty` (exit 0, no output — benched immediately, no strike), `timeout`, `hard` (auth / not-found / bad-request), `transient`.

Health is tracked **per model id across every chain**, so a model in both a tier chain and the flat chain shares one strike counter. A model with 20 attempts and 0 wins is hard-disabled permanently and survives a reset — if a model has silently stopped being used, that is why. `hard` almost always means config: check the id with `robur models list`.

## The changelog

When every task in a `## ` milestone is `[x]`, the loop moves that section out
of the tracker into `CHANGELOG.md` and commits both files
(`docs(robur): changelog for <milestone>`). Deterministic Ruby, no model call:
entries come from the task titles, the first sentence of each `do:` field, and
the commit whose subject carries the task id. The range is anchored on the last
commit that touched `CHANGELOG.md`, so there is no state file to corrupt.

The loop takes **one** milestone per turn. A repo adopting robur with a long
finished backlog is swept deliberately, by a human:

```sh
robur changelog <repo>   # archive EVERY finished milestone, once
```

Run that before the first `robur run` on such a repo; it also establishes the
anchor commit that bounds every later archive.

### Commit subjects come from the tracker

robur composes each commit from the task line — the agent never writes one. A
task's kind tag becomes the subject prefix:

```
- [ ] T4.1 (normal, feat) emit lifecycle events for stop and recovery
        ↓
feat(robur): T4.1 emit lifecycle events for stop and recovery
```

The kind (`feat|fix|perf|refactor|docs|test|chore`) is required and must never
be the FIRST tag — tier routing reads only the first. A task with no kind still
runs, under `auto(robur):`.

**Repos planned before this rule keep working**, ungrouped, under the legacy
prefix. Sweeping them is a plan edit — add a kind tag to the open tasks — and
can be done per repo, whenever each is next touched. Nothing breaks in the
meantime.

## Configuration

Two files, and the distinction is a security boundary, not a convention:

- **`.robur.conf`** (repo) is **PARSED, never sourced** — allowlisted keys only. An autonomous agent can write repo files, and the loop `eval`s `VERIFY_CMD`, so sourcing it would let anything landing in the repo execute code.
- **`~/.robur/conf`** (global) is **sourced**, because it is human-owned and needs shell expansion. `NOTIFY_CMD` may only come from here.

**Never put a `#` in any `.robur.conf` value** — parsing truncates at the first `#`, which silently cuts a `VERIFY_CMD` in half and red-locks the loop.

Operational knobs are environment variables, not conf keys: `SUMMARY_LINES`, `POLL_INTERVAL`, `ROBUR_RUNAWAY_MESSAGES`.

## Legacy names

robur was previously called ratchet. It reads the old names and writes the new ones, so nothing needs migrating:

- `.robur.conf` / `.robur/` / `~/.robur/`, falling back to `.ratchet.conf` / `.ratchet/` / `~/.ratchet/`
- `ROBUR_HOME`, `ROBUR_METRICS`, `ROBUR_LOOP`, each falling back to its `RATCHET_*` spelling
- Writes leave the legacy path as a symlink, so external tools reading `.ratchet/stop_reason` keep working

`robur migrate-state` moves live state onto the new names and symlinks the old ones. It is **dry-run by default**; pass `--apply` to act. It is idempotent and never clobbers an existing destination.
