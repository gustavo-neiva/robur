# Fixture repo

A minimal repo used only by `test/selftest.sh`. It has a tracker (`PLAN.md`),
a trivially-green verify gate (`verify.sh`), and is driven by `fake-agent` —
so the full ratchet loop runs end-to-end in CI with **no model API keys**.

Do not run the real loop against this; it does no real work.
