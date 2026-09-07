# robur

An unattended-but-safe agent loop.

robur runs a headless coding agent **one turn at a time** against a repo: it reads
the next open task from a tracker, spawns an ephemeral turn, re-runs your test
suite, and commits **only if the suite is green**. A red tree is never committed.

It survives provider rate limits by falling back down a model chain, and routes
each task to a cost tier — so a night of work stacks every provider's daily quota
into one long run instead of dying at the first 429.

Ruby, standard library only. No gems, no Bundler.

> robur is the successor to [ratchet](https://github.com/gustavo-neiva/ratchet),
> rewritten from shell into Ruby. Repos still carrying `.ratchet/` or
> `.ratchet.conf` keep working untouched — robur reads the new names first and
> falls back to the old ones.

## The mental model

Four things, and everything else follows:

1. **The tracker is the work queue.** `PLAN.md` — the first `[ ]` or
   `[IN PROGRESS]` task is what runs next.
2. **The gate is the safety model.** `VERIFY_CMD` re-runs before every commit.
   No green, no commit; the work stays staged and the next turn is handed the
   failing output to repair.
3. **Turns are ephemeral.** The agent has no memory between turns. The files are
   the memory — which is also why it costs ~90% less than a resumed session.
4. **The loop stops on purpose.** `ALL_DONE`, a human gate, a red gate that will
   not clear, or a progress stall. `.robur/stop_reason` says which.

## Install

```sh
git clone https://github.com/gustavo-neiva/robur
ln -s "$PWD/robur/exe/robur" /usr/local/bin/robur
```

Requires Ruby 3.x and a headless coding agent CLI — `pi` by default, or anything
that takes a prompt on `-p` (`--agent-cmd claude`).

## Quickstart

```sh
robur init   ~/code/myrepo    # stamp .robur.conf, AGENTS.md protocol, seed PLAN.md
robur doctor ~/code/myrepo    # preflight — must exit 0 before you run anything
robur once   ~/code/myrepo    # exactly one turn, then exit
robur run    ~/code/myrepo    # loop until ALL_DONE or a stop reason
```

**Always `robur once` before `robur run`** on a repo you have not driven before.
One turn tells you whether the prompt, the gate and the model chain are all
wired, for the cost of one turn.

Starting from nothing instead of an existing repo:

```sh
robur new "a CLI that renders GeoJSON as ASCII maps"   # scaffold + draft PLAN.md, then stop for review
```

## Watching it

```sh
robur status <repo>    # progress bars, current task, tier/model, ETA
robur watch  <repo>    # live board in a 2nd terminal, refreshed every 2s
robur stats  <repo>    # success rate, failure classes, wasted wall-hours
tail -f "$ROBUR_HOME/logs/<slug>/loop.log"
```

`$ROBUR_HOME` defaults to `~/.robur`. Per-run files live in `logs/<slug>/`:
`loop.log`, `last_turn.out` (what the agent actually said), `last_verify.out`
(why the gate went red), `events.jsonl` (structured telemetry).

## Stopping it

```sh
robur stop <repo>            # drain: finish the current turn, commit if green, exit
robur stop <repo> --now      # abort the in-flight turn, still exit cleanly
robur stop <repo> --clear    # cancel a pending stop
```

One Ctrl-C drains; a second escalates to an abort.

## Configuration

`.robur.conf` in the repo is the machine contract. It is **parsed, never
sourced** — allowlisted keys only, unknown keys are a `doctor` error. That is
deliberate: the loop `eval`s `VERIFY_CMD`, and an autonomous agent can write repo
files, so a sourced conf would let anything landing in the repo execute code
outside any agent permission model. Commands (`NOTIFY_CMD`) are only accepted in
the trusted, human-owned global conf at `~/.robur/conf`.

```conf
ROBUR_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=npm test
MODELS=zai/glm-5.3-flash,anthropic/claude-sonnet-5
```

See [`templates/robur.conf.example`](templates/robur.conf.example) for every key,
including tiered routing (`PLAN_MODELS` / `BUILD_MODELS` / `LIGHT_MODELS`),
provider allowlisting for data governance, PR cadence and merge gates, and the
timeout/cooldown knobs.

Never put a `#` in a value — parsing truncates at the first one.

## Guardrails

The interesting part of robur is what it refuses to do.

- **Never commits red.** The gate re-runs from a clean read of the repo before
  every commit, not from the agent's word.
- **Never pushes on its own.** Push and PR are opt-in (`--push`, `--pr`), and
  merging is always a human.
- **Progress guard.** No commit and no tracker change for 3 turns → bench the
  model; 6 → inject a change-your-approach note; 10 → mark the task blocked and
  advance; 15 → stop. A loop cannot spin forever on an impossible task.
- **Model health.** One strike registry keyed by model id across every chain.
  20 attempts with 0 wins hard-disables a model permanently.
- **Per-task attempt ceiling** that a strike reset cannot clear.
- **Secret scan** on the staged diff before every commit.
- **The agent may not edit `.robur.conf`.** Any turn that touches it is rejected.

## Model tiers

Each task is classified and routed to a chain, cheapest model that can do the job:

| Tier | Used for |
|---|---|
| `PLAN_MODELS` | plan-drafting turns |
| `BUILD_MODELS` | ordinary implementation turns |
| `LIGHT_MODELS` | mechanical work — renames, docs, test scaffolding |
| `REVIEW_MODELS` | milestone review turns |

Unset tier falls back to `MODELS`. `robur run --cheap` forces everything to the
light chain. Speed-tuned models (`flash`, `turbo`, `air`) are clamped to a low
reasoning budget unless you say otherwise — they spend one without earning it back.

## Claude Code / pi skills

`skills/` ships two skills: **robur** (operating a loop, diagnosing a stall) and
**robur-plan** (authoring a `PLAN.md` that one-shots a big project).

```sh
./skills/install.sh
```

## Development

Stdlib only, no Sorbet. One gate:

```sh
ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
```

`AGENTS.md` documents the design decisions that are load-bearing — each was paid
for in production. Read the reasoning before simplifying one away.

## License

[MIT](LICENSE)
