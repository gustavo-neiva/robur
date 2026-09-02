# frozen_string_literal: true

# M4 scenarios: full turn-level `once` runs through every classify_turn
# outcome. The stub agent (test/fixtures/turn-agent) is forced into one
# outcome per scenario via $FAKE_OUTCOME, so both binaries exercise the
# real run_turn/classify path with no model. Compared surfaces: stdout,
# exit code, .ratchet/last_task.state and the turn-classification metrics
# row — exactly the M4 contract (turn watchdog + classify). git log,
# loop.log/loop.pid and the trailing run-summary metrics row all depend on
# the M5 commit gate (T5.2, `commit_turn` is still a stub) and are out of
# scope here.
#
# TURN_TIMEOUT=3 keeps the timeout scenario fast; HEARTBEAT=0 QUIET=1
# strip TTY noise that is not part of the contract.
COMPARED = ["stdout", "exit code", /last_task\.state\z/, "file home/metrics.tsv[turn]"].freeze
CONF = <<~CONF
  MODELS="zai/glm-5.3-flash"
  TURN_TIMEOUT="3"
  HEARTBEAT="0"
  QUIET="1"
  VERIFY_CMD="true"
  AGENT_CMD="#{File.expand_path('../../fixtures/turn-agent', __dir__)}"
CONF

PLAN_ONE = <<~PLAN
  # Plan

  ## M1
  - [ ] T1.1 (normal) first task
PLAN

%w[step done human exhausted hard timeout transient].each do |outcome|
  scenario(
    name: "once-turn-#{outcome}",
    argv: ["once", "."],
    env: {"FAKE_OUTCOME" => outcome},
    setup: ->(repo) {
      File.write(File.join(repo, "PLAN.md"), PLAN_ONE)
      File.write(File.join(repo, ".ratchet.conf"), CONF)
    },
    only: COMPARED,
  )
end
