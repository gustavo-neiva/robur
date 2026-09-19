$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "fileutils"
require "tmpdir"
require "minitest/autorun"

# Fence ALL test telemetry into a throwaway home. Tests that forget to
# isolate used to write into the operator's real ~/.robur: 2,096 stray log
# dirs and 88 three-second turn rows in the metrics the estate reports on.
# Tests with their own ROBUR_HOME still override this.
ROBUR_TEST_HOME = Dir.mktmpdir("robur-test-home")
ENV["ROBUR_HOME"] = ROBUR_TEST_HOME
ENV.delete("RATCHET_HOME")
Minitest.after_run { FileUtils.remove_entry(ROBUR_TEST_HOME, true) }

# Fence the throwaway git repos these tests build off the OPERATOR's global
# git config, for the same reason ROBUR_HOME is fenced above. An operator with
# core.hooksPath set (a global fail-closed gitleaks pre-commit gate is the
# common case) had that hook run inside every temp repo and reject the commit,
# which reaches the assertions as an indistinguishable committed=false — so
# the allow-secret marker tests went red on a machine-specific setting rather
# than on anything in robur. The marker cannot suppress it either: gitleaks
# honours `gitleaks:allow`, not robur's own `robur:allow-secret`.
# Fencing the config, not the one scanner, is what keeps a signing hook or a
# different scanner from reopening this next time.
ROBUR_TEST_EMPTY_HOOKS = File.join(ROBUR_TEST_HOME, "empty-hooks")
FileUtils.mkdir_p(ROBUR_TEST_EMPTY_HOOKS)
ROBUR_TEST_GITCONFIG = File.join(ROBUR_TEST_HOME, "gitconfig")
# Identity is included so repos that never set one of their own still commit.
File.write(ROBUR_TEST_GITCONFIG, <<~CONF)
  [core]
  	hooksPath = #{ROBUR_TEST_EMPTY_HOOKS}
  [user]
  	name = robur-test
  	email = robur-test@example.invalid
  [commit]
  	gpgsign = false
  [init]
  	defaultBranch = main
CONF
ENV["GIT_CONFIG_GLOBAL"] = ROBUR_TEST_GITCONFIG
ENV["GIT_CONFIG_SYSTEM"] = File.join(ROBUR_TEST_HOME, "no-system-gitconfig")

require "robur"
