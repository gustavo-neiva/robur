# frozen_string_literal: true

# M1 scenarios: CLI surfaces with no repo side effects.
scenario(name: "help", argv: ["--help"])
scenario(name: "unknown-flag", argv: ["--nope"])
scenario(name: "doctor", argv: ["doctor", "."])
