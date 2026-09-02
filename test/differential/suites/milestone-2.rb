# frozen_string_literal: true

# M2 scenarios: `doctor` over a repo .ratchet.conf — config parsing parity
# (allowlist, quoting, numeric coercion, per-provider cooldown).
# Compared surface: doctor stdout + exit code (file/git surfaces unchanged).
scenario(name: "conf-valid", argv: ["doctor", "."], setup: ->(repo) {
  File.write(File.join(repo, ".ratchet.conf"), <<~CONF)
    MODELS=glm
    VERIFY_CMD=ruby -Ilib -e 'exit 0'
    COOLDOWN_OPENAI=90
  CONF
})
scenario(name: "conf-unknown-key", argv: ["doctor", "."], setup: ->(repo) {
  File.write(File.join(repo, ".ratchet.conf"), "NOT_A_KEY=1\n")
})
scenario(name: "conf-malformed", argv: ["doctor", "."], setup: ->(repo) {
  File.write(File.join(repo, ".ratchet.conf"), "this is not a conf line\n")
})
scenario(name: "conf-quoted", argv: ["doctor", "."], setup: ->(repo) {
  File.write(File.join(repo, ".ratchet.conf"), 'VERIFY_CMD="echo hi # not a comment"' + "\n")
})
scenario(name: "conf-numeric-coercion", argv: ["doctor", "."], setup: ->(repo) {
  File.write(File.join(repo, ".ratchet.conf"), "PR_SOFT_MAX_LINES=250\n")
})
scenario(name: "conf-per-provider-cooldown", argv: ["doctor", "."], setup: ->(repo) {
  File.write(File.join(repo, ".ratchet.conf"), "COOLDOWN_ZAI=120\nCOOLDOWN_ANTHROPIC=45\n")
})
