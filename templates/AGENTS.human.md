# Agent context

## Loop vs interactive

The headless `ratchet` loop briefs its own turns via the harness prompt — it
never sees this file. If you're working in a human-led session (`RATCHET_LOOP`
is unset), work normally: make as many edits as needed, run the tests, commit
when ready. The human owns the git history.

## What to read

- **PLAN.md** (or your configured tracker): the task roadmap
- **LEARNINGS.md**: mistakes, gotchas, and non-obvious behavior discovered so far

The loop keeps both current; read them before making changes.

## Project-specific rules

_(Add conventions, glossary, stack constraints, and any standing instructions
below. This section is yours to edit.)_
