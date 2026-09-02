#!/usr/bin/env bash
# fixture green gate — trivially green so the commit gate passes in CI.
# A real repo's gate is its test suite (npm test, mix test, pytest, ...). This
# stub only proves the loop re-runs VERIFY_CMD before each commit.
set -euo pipefail
[ -f PLAN.md ] || { echo "verify: PLAN.md missing"; exit 1; }
exit 0
