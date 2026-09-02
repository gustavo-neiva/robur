# Learnings

> Append-only guardrails the agent discovers while working on this repo.
> Read this before each turn; add new gotchas you hit (one bullet per line).
> A planner turn prunes stale entries periodically. The loop never depends on
> this file — it is advisory memory, not state.

- _(example)_ `npm test` must run from the repo root; a nested cwd makes it red.
- `File.expand_path("../lib", file_path)` keeps the filename — always expand against `File.dirname` (cost a turn in T1.1).
