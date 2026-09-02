# frozen_string_literal: true

# M5 scenarios: the commit gate (T5.2) and observability (T5.3-5.5) wired
# into `once` via CommitGate. Compared surfaces are exactly the ones T5.6
# names: loop.log, the metrics.tsv row(s), and `git log --format='%s'`
# (commit subjects, not just the count) — stdout/exit code are NOT in scope
# here (they still carry the M4 turn-classification surface, already
# covered by milestone-4.rb).
M5_COMPARED = [/loop\.log\z/, /metrics\.tsv\[(turn|run)\]\z/, "git log"].freeze

M5_TURN_AGENT = File.expand_path("../../fixtures/turn-agent", __dir__)

M5_PLAN_ONE = <<~PLAN
  # Plan

  ## M1
  - [ ] T1.1 (normal) first task
PLAN

m5_conf = lambda do |verify_cmd, extra = ""|
  <<~CONF
    MODELS="zai/glm-5.3-flash"
    TURN_TIMEOUT="5"
    HEARTBEAT="0"
    QUIET="1"
    VERIFY_CMD="#{verify_cmd}"
    COMMIT_EACH_TURN="1"
    COMMIT_VERIFY_GATE="1"
    AGENT_CMD="#{M5_TURN_AGENT}"
    #{extra}
  CONF
end

m5_setup = lambda do |verify_cmd, conf_extra: "", extra_file: nil|
  ->(repo) {
    File.write(File.join(repo, "PLAN.md"), M5_PLAN_ONE)
    File.write(File.join(repo, ".ratchet.conf"), m5_conf.call(verify_cmd, conf_extra))
    if extra_file
      name, content = extra_file
      File.write(File.join(repo, name), content)
    end
  }
end

# 1) green commit: VERIFY_CMD green, step turn -> one commit, mined subject.
scenario(
  name: "commit-gate-green-commit",
  argv: ["once", "."],
  env: {"FAKE_OUTCOME" => "step"},
  setup: m5_setup.call("true"),
  only: M5_COMPARED,
)

# 2) red gate: VERIFY_CMD fails -> nothing committed, work left staged.
scenario(
  name: "commit-gate-red-gate",
  argv: ["once", "."],
  env: {"FAKE_OUTCOME" => "step"},
  setup: m5_setup.call("false"),
  only: M5_COMPARED,
)

# 3) each secret-scan block (same 5 fixture shapes as commit_gate_test.rb).
m5_secrets = {
  "private-key" => ["id_rsa", "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n"], # ratchet:allow-secret
  "aws-key" => ["conf.txt", "AWS_KEY=AKIAABCDEFGHIJKLMNOP\n"], # ratchet:allow-secret
  "sk-key" => ["conf.txt", "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx\n"], # ratchet:allow-secret
  "jwt" => ["conf.txt",
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0." \
            "SflKxwRJSMeKKF2QT4fwpMeJf36POk6y\n"], # ratchet:allow-secret
  "dotenv" => [".env", "SECRET=1\n"],
}

m5_secrets.each do |name, extra_file|
  scenario(
    name: "commit-gate-secret-block-#{name}",
    argv: ["once", "."],
    env: {"FAKE_OUTCOME" => "step"},
    setup: m5_setup.call("true", extra_file: extra_file),
    only: M5_COMPARED,
  )
end

# 4) idempotent turn: nothing staged (the "human" outcome touches no file).
# PLAN.md is committed into a seed commit first — plain m5_setup would
# leave PLAN.md's own overwrite as the "staged diff", never exercising the
# nothing-staged path. .ratchet.conf stays untracked, same as every other
# scenario here (it is always excluded before the staged-diff check).
scenario(
  name: "commit-gate-idempotent-turn",
  argv: ["once", "."],
  env: {"FAKE_OUTCOME" => "human"},
  setup: ->(repo) {
    File.write(File.join(repo, "PLAN.md"), M5_PLAN_ONE)
    File.write(File.join(repo, ".ratchet.conf"), m5_conf.call("true"))
    system("git", "-C", repo, "add", "-A", out: File::NULL, err: File::NULL)
    system("git", "-C", repo, "reset", "-q", "--", ".ratchet.conf", out: File::NULL, err: File::NULL)
    system("git", "-C", repo, "-c", "user.name=fixture", "-c", "user.email=fixture@example.com",
           "-c", "commit.gpgsign=false", "commit", "-q", "-m", "seed", out: File::NULL, err: File::NULL)
  },
  only: M5_COMPARED,
)

# 5) .ratchet.conf tamper attempt: a secret-shaped value sits in an
# allowlisted, behaviour-inert key (FANOUT only matters for (hard) tasks;
# this tracker's only task is (normal)). The gate must exclude
# .ratchet.conf from staging BEFORE the secret scan runs, so the turn's
# real commit still lands — proving the exclude, not just the scan.
scenario(
  name: "commit-gate-conf-tamper",
  argv: ["once", "."],
  env: {"FAKE_OUTCOME" => "step"},
  setup: m5_setup.call("true", conf_extra: 'FANOUT="AKIAABCDEFGHIJKLMNOP"'),
  only: M5_COMPARED,
)
