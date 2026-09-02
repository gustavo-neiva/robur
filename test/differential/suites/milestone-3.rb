# frozen_string_literal: true

# M3 scenarios: the tracker grammar, driven through `status` (no-log path)
# and `once` (preflight gate) against six PLAN.md variants. The doctor
# tracker check — open/fully-done/NO-tasks plus the unresolved-id pin — is
# the tracker-grammar surface both binaries expose today; the full turn loop
# lands with M4+.
#
# Every scenario omits .ratchet.conf so baseline `once` aborts at preflight
# (before any model call); exit code, stdout and the resulting PLAN.md are
# compared.
VARIANTS = {
  # tagged: id + (tier) tag — the canonical line
  "tagged" => <<~PLAN,
    # Plan

    ## M1
    - [ ] T1.1 (normal, serial) first task
    - [ ] T1.2 (trivial) second task
  PLAN
  # untagged: id, no parenthesised tier
  "untagged" => <<~PLAN,
    # Plan

    ## M1
    - [ ] T1 first task
    - [ ] T2 second task
  PLAN
  # indented checkboxes: tracker_has_open's leading-[[:space:]] tolerance
  "indented" => <<~PLAN,
    # Plan

    ## M1
      - [ ] T1.1 (normal) first task
      - [ ] T1.2 (normal) second task
  PLAN
  # all-done: doctor reports fully-done, loop would final-commit
  "all-done" => <<~PLAN,
    # Plan

    ## M1
    - [x] T1.1 (normal) first task
    - [x] T1.2 (normal) second task
  PLAN
  # placeholder-seeded: _(…)_ marker outside backticks, still open tasks
  "placeholder" => <<~PLAN,
    # Plan

    ## M1
    - [ ] T1.1 (normal) first task
    _(decide: storage engine)_
  PLAN
  # greedy-paren regression (tracker.sh:145): tier tag first, "(hard)" in title
  "greedy-paren" => <<~PLAN,
    # Plan

    ## M1
    - [ ] T1.1 (trivial) fix the (hard) matching
  PLAN
}.freeze

VARIANTS.each do |name, plan|
  setup = ->(repo) { File.write(File.join(repo, "PLAN.md"), plan) }
  scenario(name: "status-#{name}", argv: ["status", "."], setup: setup)
  scenario(name: "once-#{name}", argv: ["once", "."], setup: setup)
end
