# frozen_string_literal: true

# M1 scenarios: CLI surfaces with no repo side effects.
scenario(name: "help", argv: ["--help"])
scenario(name: "unknown-flag", argv: ["--nope"])
# OptionParser hands Ruby a free --version (and -V) that bash does not have;
# without this scenario that freebie silently diverges from bash's FATAL.
scenario(name: "version-flag", argv: ["--version"])
scenario(name: "doctor", argv: ["doctor", "."])
