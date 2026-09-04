---
name: robur-plan
description: Author a robur PLAN.md that one-shots big projects. Use when building a plan for the robur autonomous loop, tagging tasks for tiered model routing (plan/build/light), writing self-contained tasks with Given/When/Then acceptance, or when the user says "robur plan", "make a plan for the loop", or "spec this for autonomous build".
---

# robur-plan

Turn a goal into a `PLAN.md` the robur loop can execute **unattended and one turn at a time**, with the right model on every task. A good robur plan is a spec that a fresh, memoryless agent turn can pick up, do ONE step, and leave green.

## The one fact that shapes everything

robur turns are **ephemeral**. Each turn spawns the agent with `--no-session`, so it starts with **no memory of any prior turn**. The on-disk memory is the files: `PLAN.md`, `LEARNINGS.md`, and the code itself. `AGENTS.md` is human/project memory — what the repo is, how to work here, gotchas.

The loop protocol does *not* live in `AGENTS.md`. robur composes each turn's prompt in code (`Robur::Prompt.for_turn`) from four parts:

1. the base instruction (do ONE step, write to files, print `STEP_COMPLETE` or `ALL_DONE`),
2. **your task, quoted verbatim from the tracker**,
3. the previous turn's note (gate GREEN/RED + what changed),
4. the tail of `last_verify.out`, but only when the gate is RED.

So a memoryless turn gets its instructions fresh regardless of what `AGENTS.md` says — and **every task must be self-contained**: name the files, name the functions, state the "why", and state how the loop knows it's done. A task that assumes context from a previous turn will fail, because there is no previous turn.

### Your task block is capped at 40 lines

robur quotes the task into the prompt and truncates at 40 lines with a `… (task block truncated)` marker. A task longer than that **silently loses its tail** — usually `verify` and `constraints`, the two fields that decide whether the turn is gated correctly.

Keep every task under 40 lines including its indented fields. If it does not fit, that is the planner telling you the task is really two tasks.

## Tags are the model-selection contract

The tag on each task routes it to a model tier. This is not decoration — it is how "plan with the strong model, build with the mid model, search with the cheap model" becomes mechanical instead of vibes.

| Tag | Tier | Model class | Use for |
|---|---|---|---|
| `(trivial)` | LIGHT | cheap, thinking forced off | mechanical edits, search, data collection, doc tweaks, moving text |
| `(normal)` | BUILD | mid (sonnet-class) | real implementation, the bulk of the work |
| `(hard)` | BUILD chain + thinking bump | mid with reasoning raised one notch | tricky logic, blast-radius-wide changes, anything needing review |
| `(serial)` | — | (any tier) | add when the task must NOT run in parallel with siblings (shared files) |

Only `trivial` and `hard` are special-cased; **anything else — including a missing tag — routes to BUILD**. So an untagged task is not an error, it is a silent default. Decide on purpose.

`(trivial)` also forces thinking off, and models whose names match `flash|turbo|highspeed|air` get the light thinking treatment regardless of tier. Do not tag something `trivial` to save money if it needs to reason — the green gate is the safety net, but a task that cannot succeed just burns turns until the progress guard blocks it.

**Auto-tag at authoring time.** As you draft each task, assign `(trivial|normal|hard)` with a one-line justification for any non-obvious choice. The human reviews at the mandatory checkpoint before any run; tagging happens during drafting, not as a separate pass. When genuinely torn between two tiers, pick the cheaper one.

## Task ID formats (CRITICAL — the parser must recognize these)

Every task needs an ID the parser can extract:

- **`T1.2`** — classic milestone.task (most common, use this by default)
- **`A1`, `I3`** — letter(s) + number
- **`N-postmortem`** — letter + dash + slug

The ID must be uppercase letters followed by digits, `major.minor`, or `-slug`.

**CRITICAL:** Do NOT wrap IDs in bold or italic markdown:

```markdown
# WRONG — the parser sees ** and gives up
- [ ] **T1.4** (hard) implement feature

# CORRECT — parses as T1.4
- [ ] T1.4 (hard) implement feature
```

A bold ID does not fail loudly. It yields id `?`, which means the metrics row, the state file and the log line all say `?`, the progress guard cannot tell one task from another, and `doctor` warns that a task id is unresolved. Bold belongs in the description, never around the ID.

Only the **first** parenthesised group after the ID is read as tags, so `- [ ] T1.1 (normal) rewrite parse(x) (fast path)` is safe — the trailing parens are description.

## Tracker grammar

`- [ ] open` → `- [IN PROGRESS] in progress` → `- [x] done`.

All three are recognized, plus `[X]`. Tasks under a heading matching *done* or *checklist* are skipped when counting open work, so a "## Done" section does not resurrect finished tasks.

## The task schema

One tracker line plus indented fields. The tracker line is what robur parses; the fields are what the agent reads to do the work in ONE turn.

```
- [ ] T1.4 (hard, serial) <imperative one-line goal — what exists after this task>
      touches: lib/robur/model_health.rb, lib/robur/loop.rb
      do: <2-4 sentences. What to change, which function, and WHY. Repeat any
          assumption — the turn has no memory. Name paths and functions exactly.>
      snippet:
          def pick(models) = models.find { |m| !benched?(m) }
      accept:
          Given a model with 3 recorded transient failures
          When the loop selects a model for the next turn
          Then that model is skipped and the log names the bench reason
      verify: ruby -Ilib -e 'Dir["test/**/*_test.rb"].each{|f| require File.expand_path(f)}'
      constraints: stdlib only; no new conf keys; never edit .robur.conf
```

Field rules:

- **touches** — exact repo-relative paths the task will edit. This is the parallel-safety signal: two tasks sharing a path must both be `(serial)`.
- **do** — prose, not a checklist. State the change, the function/module by name, and the reason. Over-explain user-visible effects; under-specify incidental details.
- **snippet** — optional. A signature, a case arm, an anchor line. Enough to remove ambiguity, not the whole implementation. Indent it (no nested code fences).
- **accept** — Given/When/Then, phrased as **observable behavior**, not internal attributes. "Then the CLI prints X", not "Then a struct is added". This is both the spec the agent codes toward and the shape of the test that gates it.
- **verify** — the exact command that must pass, plus the new case(s) this task adds. This is `VERIFY_CMD`; a RED result blocks the commit and the next turn is handed the failing tail to repair.
- **constraints** — the non-negotiables: additive-only, runtime limits, forbidden files.

**Why prose + Given/When/Then, never pure Gherkin:** Gherkin-only prompts generate near-zero working code — the model needs the "why" and the repo context that prose carries. But Given/When/Then is an excellent *oracle*: it maps straight onto a pass/fail test. Prose drives generation; Given/When/Then drives verification. Never invert this.

## What the loop does when a task goes wrong

Plan around this rather than being surprised by it. robur tracks "no progress" as *no commit and no tracker change*, and escalates:

| Stalled turns | What happens |
|---|---|
| 3 | benches the current model, switches to the next in the chain |
| 6 | injects a "you are repeating yourself, change approach" note into the prompt |
| 10 | marks the task `[x] … — BLOCKED by progress guard` and moves on |
| 15 | stops the loop for a human |

A task that cannot be finished in one turn does not block forever — it gets **marked done with a BLOCKED note** and the loop advances. That is deliberate, but it means an over-large task quietly becomes a lie in your tracker. Split tasks so this never fires.

The gate is what actually protects you: no green, no commit. A RED turn leaves work staged and hands the next turn the verify tail.

## PLAN.md structure

```
# PLAN.md — <project>: <what this plan delivers>

Tracker grammar: [ ] open → [IN PROGRESS] → [x] done. Tags: (trivial|normal|hard) and (serial).

## Design constraints (read before ANY task — non-negotiable)
1. <invariant every turn must hold — e.g. zero regressions, additive only>
2. <runtime/style limits>
3. One task per turn. Do the task, add its verify case, run VERIFY_CMD, mark [x], print STEP_COMPLETE.

## Milestone 0 — walking skeleton + green gate (serial)
> No feature task runs before this is green. The safety model (no green, no commit) is bootstrapped here.
- [ ] T0.1 (trivial, serial) scaffold + wire VERIFY_CMD
- [ ] T0.2 (normal, serial) first end-to-end test is green
- [ ] T0.3 (normal) thinnest end-to-end slice of real value

## Milestone 1 — <feature> (serial if tasks share files)
- [ ] T1.1 (normal) ... <full task schema>

## Definition of done
- All tasks [x]. VERIFY_CMD green on a clean checkout. <project-specific criteria>

## Non-goals
- <what is explicitly OUT of scope>
```

Milestone 0 is mandatory and always first: a green walking skeleton before any feature. It bootstraps "no green, no commit". Never skip it.

Living-document memory: decisions and gotchas go in `LEARNINGS.md` (append-only, read every turn). Progress lives in the tracker checkboxes. You do not need a separate decision log — `LEARNINGS.md` + the tracker are the robur equivalent.

## The authoring flow

Interview first — the best plans come from a rich brief, not a vague one.

1. **Rearticulate.** State the goal and non-goals back in 2-3 sentences. Confirm before decomposing. If the goal is vague, do shallow read-only exploration to ground it.
2. **Design constraints.** Write the invariants every turn must hold. These become the "read before ANY task" block.
3. **Milestone 0.** Define the walking skeleton whose VERIFY_CMD is green. Nothing else runs before it.
4. **Decompose.** Milestones, then tasks. Each task = one discrete step a single turn can finish. If it cannot fit one turn — or 40 lines — split it.
5. **Fill the schema.** For each task: touches / do / snippet / accept / verify / constraints. Name real paths and functions; open the files if you must. Assign the tier tag as you go. Mark `(serial)` on every task sharing a `touches` path with a sibling.
6. **Hand off.** Write `PLAN.md`, then the human reviews it (mandatory) before `robur run`. Drafting inside the loop via `robur plan` stops loudly for this review and never auto-runs.

## Checklist before you hand off

- [ ] Milestone 0 exists and its verify gate can go green first.
- [ ] Every task ID is a recognized format (`T1.2` / `A1` / `N-slug`) with NO bold or italics around it.
- [ ] Every task has a tier tag; non-obvious tags carry a one-line justification.
- [ ] Every task fits in 40 lines including its fields.
- [ ] Every task is self-contained — a memoryless turn could do it from the task text alone.
- [ ] Every task names exact paths (`touches`) and the `verify` command + new case.
- [ ] Tasks sharing a `touches` path are all `(serial)`.
- [ ] `accept` is observable behavior, not internal attributes.
- [ ] Definition of done and Non-goals are written.

## Reference

robur's own `PLAN.md` ("robur builds robur") is the worked example of this schema — every task carries paths, functions and its verify cases inline. Read it when you need a concrete model.

Verify a draft before handing it over: `robur doctor <repo>` reports whether the tracker has open work, whether task ids resolve, and whether the tier chains are configured.
