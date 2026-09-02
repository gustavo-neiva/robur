# frozen_string_literal: true

# T7.1: the parity gate. Composes every milestone suite (M1-M6) into one
# run, plus a long-run scenario that drives the fixture repo from an empty
# (all-open) tracker all the way to ALL_DONE across many turns and multiple
# milestones with the fake-agent. `ruby test/differential/run.rb --suite
# parity` is the single command that proves feature parity end to end.
Dir.glob(File.join(__dir__, "milestone-*.rb")).sort.each { |f| load f }

PARITY_AGENT = File.expand_path("../../fixtures/fake-agent", __dir__)

# Nine tasks across three milestones so the run exercises: many turns, a
# milestone rollover, and the final ALL_DONE turn — the fake-agent ticks
# exactly one task per invocation, so this is a real multi-turn loop, not a
# single-shot run like milestone-6's 2-task "run-to-done" scenario.
PARITY_LONG_PLAN = <<~PLAN
  # Plan

  ## M1
  - [ ] T1.1 (trivial) first task
  - [ ] T1.2 (trivial) second task
  - [ ] T1.3 (trivial) third task

  ## M2
  - [ ] T2.1 (trivial) fourth task
  - [ ] T2.2 (trivial) fifth task
  - [ ] T2.3 (trivial) sixth task

  ## M3
  - [ ] T3.1 (trivial) seventh task
  - [ ] T3.2 (trivial) eighth task
  - [ ] T3.3 (trivial) ninth task
PLAN

parity_conf = <<~CONF
  MODELS="zai/glm-5.3-flash"
  TURN_TIMEOUT="5"
  HEARTBEAT="0"
  QUIET="1"
  VERIFY_CMD="true"
  COMMIT_EACH_TURN="1"
  AGENT_CMD="#{PARITY_AGENT}"
CONF

parity_setup = lambda { |repo|
  File.write(File.join(repo, "PLAN.md"), PARITY_LONG_PLAN)
  File.write(File.join(repo, ".ratchet.conf"), parity_conf)
}

scenario(name: "long-run-empty-tracker-to-all-done", argv: ["run", "."], setup: parity_setup)
