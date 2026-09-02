# frozen_string_literal: true

# M6 self-QA (T6.7): one differential scenario per subcommand the CLI now
# ports — run, once, init, new, plan, plan --auto, doctor, status, stats,
# models, fanout, fanout-clean. Each scenario picks the SMALLEST config that
# drives the command through its default/deterministic path with no api
# keys and no network — the fake-agent stands in for every turn, and gh/
# origin-remote-dependent fanout paths are exercised only up to their
# preflight gate (real gh flows are covered by test/pr_flow_test.rb against
# a FakeRepo double, not here).
M6_AGENT = File.expand_path("../../fixtures/fake-agent", __dir__)

M6_PLAN_TWO = <<~PLAN
  # Plan

  ## M1
  - [ ] T1.1 (trivial) first task
  - [ ] T1.2 (trivial) second task
PLAN

m6_conf = lambda do |extra = ""|
  <<~CONF
    MODELS="zai/glm-5.3-flash"
    TURN_TIMEOUT="5"
    HEARTBEAT="0"
    QUIET="1"
    VERIFY_CMD="true"
    COMMIT_EACH_TURN="1"
    AGENT_CMD="#{M6_AGENT}"
    #{extra}
  CONF
end

m6_setup = lambda do |extra = ""|
  ->(repo) {
    File.write(File.join(repo, "PLAN.md"), M6_PLAN_TWO)
    File.write(File.join(repo, ".ratchet.conf"), m6_conf.call(extra))
  }
end

# `run`: the full loop to ALL_DONE against a 2-task tracker.
scenario(name: "run-to-done", argv: ["run", "."], setup: m6_setup.call)

# `once`: one turn, ticks T1.1.
scenario(name: "once-one-turn", argv: ["once", "."], setup: m6_setup.call)

# `doctor`: preflight over the same repo (already covered more thoroughly by
# milestone-1/2, one representative case here for command-surface coverage).
scenario(name: "doctor-ok", argv: ["doctor", "."], setup: m6_setup.call)

# `status`: no loop.log yet (nothing run in THIS scenario's fixture copy) —
# the one status path reachable without also reproducing a prior run's
# home-side log tree in setup (setup only ever touches the repo).
scenario(name: "status-no-log", argv: ["status", "."])

# `stats`: no loop.log yet either — exercises the die "no loop.log found"
# path added by this task's CLI wiring (Observability.stats was already
# ported in T5.5; only the `stats` dispatch arm was missing).
scenario(name: "stats-no-log", argv: ["stats", "."], setup: m6_setup.call)

# `init`: bare repo (no .ratchet.conf yet) -> stamped conf/AGENTS.md/PLAN.md.
scenario(name: "init-bare", argv: ["init", "."], setup: ->(repo) {
  FileUtils.rm_f(File.join(repo, "PLAN.md")) # exercise the "no tracker" seed path too
})

# `new`: scaffolds its OWN git repo at a relative subdir — no turn, no
# network, pure file/git scaffolding. bin/ratchet's generic pre-dispatch
# REPO_DIR resolution does `cd "$REPO_DIR" && pwd` BEFORE cmd_new ever
# runs, so an explicit dir arg must already exist (cmd_new's own
# `dir="$PWD/$name"` default is unreachable through the CLI — main()
# always resolves REPO_DIR first). Restricted to stdout/exit code: the
# harness's file snapshot only walks `<repo>/.ratchet` and $HOME, neither of
# which `new`'s subdir touches, so the outer repo's `git log`/files are
# trivially unaffected on both sides regardless.
scenario(
  name: "new-scaffold",
  argv: ["new", "a tiny cli tool", "scaffolded"],
  setup: ->(repo) { FileUtils.mkdir_p(File.join(repo, "scaffolded")) },
  only: ["stdout", "exit code"],
)

# `plan`: ONE plan-drafting turn (PLAN tier), then the review-stop banner.
scenario(name: "plan-one-turn", argv: ["plan", "."], setup: m6_setup.call)

# `plan --auto`: AUTOPLAN tier, no review-stop.
scenario(name: "plan-auto", argv: ["plan", "--auto", "."], setup: m6_setup.call)

# `fanout`: default conf has no PARALLEL=1 -> deterministic preflight-gate
# message, no gh/origin/network needed. The gh-dependent path beyond this
# gate (worktree creation, parallel `run` launches) is covered by
# test/pr_flow_test.rb's FakeRepo-based unit tests, not differentially —
# see the `unsupported` entry below.
scenario(name: "fanout-requires-parallel", argv: ["fanout", "."], setup: m6_setup.call)

# `fanout-clean`: fresh repo, no extra worktrees -> removed=0 kept=0.
scenario(name: "fanout-clean-empty", argv: ["fanout-clean", "."], setup: m6_setup.call)

# `models`: `list` shells out to the REAL `pi --list-models` on both sides
# (bash lib/models.sh:35, robur ModelsCmd.pi_model_registry with
# refresh: true) to validate/mark the configured chains. That call is
# live, auth-and-network-dependent, and not part of either side's OWN
# ported logic — it produces the same output on both sides only when `pi`
# is reachable and returns a stable registry, which the differential
# harness cannot guarantee. Structurally uncomparable: listed here, not
# silently dropped from the suite. (ModelsCmd's own chain-editing logic —
# add/remove/thinking/rank — is unit-tested deterministically against a
# FakeProc double in test/models_cmd_test.rb.)
unsupported(name: "models-list", reason: "shells out to live `pi --list-models` on both sides (network/auth-dependent, not comparable)")
