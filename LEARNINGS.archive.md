# Learnings — ARCHIVE (closed-milestone notes)

> Moved out of LEARNINGS.md (audit Q9: static context floor — the file was
> 24.5KB and re-read every turn). Closed-milestone narratives; the actionable
> gotchas live on in LEARNINGS.md and code comments. Pruned 2026-09-04 to
> entries that still explain live code — retired-surface notes (differential
> harness, bash-parity pins) were deleted, not archived again.

- `Commands.doctor_report`'s tier-routing block reads the repo-only `conf_values`, NOT full `Config.load` (matching `AGENT_CMD`/`VERIFY_CMD`) — doctor warnings about tier keys are repo-scoped by design; the loop itself resolves repo+global.
- T6.6 (models_cmd): `rank`/`list`'s derived-chain suggestion always takes the "no cost signal" branch (no model-cost port) — a `ponytail:` comment in the file names the upgrade path. `pi_model_registry` rescues `Errno::ENOENT` instead of a separate `command -v pi` probe.
- T6.6 (wait_for_merge / open_milestone_pr): `MERGE_POLL_SECS`/`MERGE_WAIT_TIMEOUT` have NO Config defaults — inline `${VAR:-N}` at the one call site, not invented as allowlist keys. `Plan#completed_list` keeps the `[x]` marker (only strips the leading `-`), so it is a separate method from the subject miner. Tested with injected FakeRepo/FakeGh doubles, not PATH-stubbed scripts.
- T6.6 (fanout): the milestone slug is NOT lowercased. Launch/wait steps are injectable procs. `Process.wait` (no args) is Ruby's `wait -n`; reaped pids must be tracked so the final sweep doesn't re-`Process.waitpid` and raise `Errno::ECHILD`.
- T6.6 (auto_plan_pr0): reuses `Commands.plan_turn` (the same helper the plan command calls); on failure it returns an Integer the caller returns immediately, skipping pid-file/loop/epilogue. PR #0 body is scoped to the TRACKER_FILE diff's ADDED lines only.
- T6.6 (milestone_complete_check / run_review_turn): the review turn's thinking arg is the JUST-FINISHED build turn's `Tier.thinking_for` value — the main loop never resolves a "review" tier (quirk preserved). `Loop.commit_review_injected_tasks` gates on a REAL `File.directory?(".git")` even with an injected fake repo — tests need `FileUtils.mkdir_p(dir/.git)`.
- Every `cmd_*`/helper whose last expression is a bare non-zero value leaks it as the process exit code — grep for a bare final expression when a command exits wrong.
