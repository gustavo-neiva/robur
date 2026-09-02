# Plan

> Tracker grammar: status `[ ]` open · `[IN PROGRESS]` · `[x]` done, plus an
> optional id and optional tags `(trivial|normal|hard)` and/or `serial`.
> The loop takes the `[IN PROGRESS]` task, else the first `[ ]`.
>
> Task IDs: `T1.2` (classic), `A1`/`I3` (letter+number), or `N-slug` (letter-dash-slug).
> NO bold/italic markdown around IDs or parser fails with "task id unresolved".
>
> Tags route each task to a model tier: `(trivial)`→LIGHT (cheap, no reasoning),
> `(normal)`→BUILD, `(hard)`→BUILD with reasoning bumped. The planner assigns
> tier tags at authoring time with a one-line justification for non-obvious choices.
> Every task is done by ONE ephemeral turn with NO memory of prior turns — so
> each task must be self-contained: name the files, the "why", and how to verify.
> Author with the `ratchet-plan` skill. See the ratchet repo's own PLAN.md for a
> worked example of the task schema below.
>
> Size each milestone as ONE reviewable unit (a feature/subfeature a human can
> read as a single PR, target ≤~400 changed lines) — milestones are the
> review/PR boundary, not just headings.

## Design constraints (read before ANY task — non-negotiable)
1. _(e.g. zero regressions; the verify gate stays green every turn)_
2. _(runtime/style limits — language version, forbidden patterns)_
3. One task per turn: do it, add its verify case, run `VERIFY_CMD`, mark `[x]`, print the step token.

## Milestone 0 — Walking skeleton + green gate
> No feature task runs before this milestone is green. The loop's safety model
> (no green, no commit) is bootstrapped right here.

- [ ] T0.1 (trivial, serial) scaffold the project and wire the verify command
      touches: _(exact paths)_
      do: _(what to scaffold; which command becomes VERIFY_CMD and why)_
      accept: Given a fresh checkout / When VERIFY_CMD runs / Then it exits green
      verify: _(exact command)_
      constraints: _(optional: non-negotiables for this task)_
- [ ] T0.2 (normal, serial) first end-to-end test is green (`VERIFY_CMD` passes)
- [ ] T0.3 (normal) thinnest end-to-end slice of real value

## Milestone 1 — _(replace with your feature milestones)_
- [ ] T1.1 (normal) _first real task — full schema_
      touches: _(exact repo-relative paths this task edits)_
      do: _(2-4 sentences: what to change, which function, WHY. Repeat assumptions.)_
      snippet: _(optional signature/anchor, indented — no nested code fences)_
      accept: Given _(precondition)_ / When _(action)_ / Then _(observable behavior)_
      verify: _(exact command + the new case this task adds)_
      constraints: _(non-negotiables for this task)_
- [ ] T1.2 (hard, serial) _a task with tricky logic that must not run in parallel_

## Definition of done
- All tasks `[x]`.
- `VERIFY_CMD` green on a clean checkout.
- _(add your own done-criteria here)_

## Non-goals
- _(explicitly list what is OUT of scope)_
