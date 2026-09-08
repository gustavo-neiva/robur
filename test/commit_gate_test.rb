# frozen_string_literal: true

require_relative "test_helper"
require "robur/commit_gate"
require "robur/paths"
require "robur/task"
require "tmpdir"
require "open3"

module Robur
  class CommitGateTest < Minitest::Test
    # The gate asks the plan for the Task it completed; a nil task is the
    # "nothing identifiable" path and commits under `auto(robur): step`.
    FakePlan = Struct.new(:line) do
      def completed_task(dispatched = nil) = line.nil? ? dispatched : Task.parse(line)
    end

    def fake_plan(line = "- [x] T1.1 (normal, feat) do the thing") = FakePlan.new(line)

    def git_repo
      dir = Dir.mktmpdir
      git(dir, "init", "-q", "-b", "main")
      git(dir, "config", "user.email", "t@example.com")
      git(dir, "config", "user.name", "T")
      File.write(File.join(dir, "f.txt"), "hi\n")
      git(dir, "add", "f.txt")
      git(dir, "commit", "-q", "-m", "init")
      dir
    end

    def git(dir, *args) = system("git", "-C", dir, *args, out: File::NULL, err: File::NULL)

    def config(overrides = {})
      { "COMMIT_EACH_TURN" => "1", "COMMIT_VERIFY_GATE" => "1", "VERIFY_CMD" => "true",
        "VERIFY_TIMEOUT" => "600", "COMMIT_EXCLUDE_GLOBS" => "" }.merge(overrides)
    end

    def gate(dir, cfg = config)
      CommitGate.new(dir, plan: fake_plan, config: cfg)
    end

    # The subject is changelog-grade: conventional-commit kind from the task's
    # tag, then id and title. Tier tags are routing metadata and are dropped;
    # turn and model are debugging data and live in the body.
    def test_green_tree_commits_once_with_mined_subject
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      result = gate(dir).run(turn: 3, model: "acme/model")
      assert result.committed
      out, = Open3.capture3("git", "-C", dir, "log", "--format=%s%n%b", "-1")
      assert_equal "feat(#{Paths::COMMIT_SCOPE}): T1.1 do the thing", out.lines.first.chomp
      assert_includes out, "Autonomous loop turn 3. verify: green."
      assert_includes out, "model: acme/model"
    end

    # A task with no kind tag predates the required-kind rule and must still
    # commit, under the legacy prefix.
    def test_task_without_a_kind_tag_falls_back_to_the_auto_prefix
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      plan = fake_plan("- [x] T2.9 (normal) untagged legacy task")
      assert CommitGate.new(dir, plan: plan, config: config).run(turn: 1, model: "m").committed
      out, = Open3.capture3("git", "-C", dir, "log", "--format=%s", "-1")
      assert_equal "auto(#{Paths::COMMIT_SCOPE}): T2.9 untagged legacy task\n", out
    end

    # The dispatched task is the fallback when the turn staged no tracker
    # diff. Without it the gate guessed "newest [x] anywhere in the file",
    # which silently attributes a commit to an unrelated task — and the
    # changelog joins entries to commits by exactly that id.
    def test_dispatched_task_titles_the_commit_when_the_plan_has_no_staged_line
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      dispatched = Task.parse("- [ ] T7.7 (normal, fix) repair the thing")
      result = CommitGate.new(dir, plan: FakePlan.new(nil), config: config)
                          .run(turn: 1, model: "m", task: dispatched)
      assert result.committed
      out, = Open3.capture3("git", "-C", dir, "log", "--format=%s", "-1")
      assert_equal "fix(#{Paths::COMMIT_SCOPE}): T7.7 repair the thing\n", out
    end

    # The body used to claim "verify: green." on the two paths that ran no
    # gate at all — including the one that had just warned about exactly that.
    # A changelog built from these commits would inherit the lie.
    def test_commit_body_never_claims_green_when_no_gate_ran
      { config("VERIFY_CMD" => "") => "verify: none (VERIFY_CMD empty)",
        config("COMMIT_VERIFY_GATE" => "0") => "verify: skipped (COMMIT_VERIFY_GATE off)" }.each do |cfg, note|
        dir = git_repo
        File.write(File.join(dir, "new.txt"), "hello\n")
        assert gate(dir, cfg).run(turn: 1, model: "m").committed
        out, = Open3.capture3("git", "-C", dir, "log", "--format=%b", "-1")
        assert_includes out, note
        refute_includes out, "verify: green"
      end
    end

    def test_red_verify_cmd_blocks_and_leaves_work_staged
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      result = gate(dir, config("VERIFY_CMD" => "false")).run(turn: 1, model: "m")
      refute result.committed
      assert_equal "commit gate RED", result.block_reason
      out, = Open3.capture3("git", "-C", dir, "diff", "--cached", "--name-only")
      assert_equal "new.txt\n", out
    end

    def test_empty_verify_cmd_is_a_loud_warning_not_a_silent_skip
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      result = gate(dir, config("VERIFY_CMD" => "")).run(turn: 1, model: "m")
      assert result.committed
      assert result.verify_cmd_empty
    end

    def test_zero_added_lines_is_clean_and_commit_proceeds
      dir = git_repo
      File.delete(File.join(dir, "f.txt"))
      result = gate(dir).run(turn: 1, model: "m")
      assert result.committed
      assert_nil result.block_reason
    end

    def test_nothing_staged_skips_cleanly
      dir = git_repo
      result = gate(dir).run(turn: 1, model: "m")
      refute result.committed
      assert_nil result.block_reason
    end

    # robur:allow-secret — these are synthetic fixture shapes for the scanner
    # under test, not real credentials; the outer commit gate's own scan would
    # otherwise block committing this test file.
    def test_blocks_private_key
      assert_blocked("id_rsa", "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n", # robur:allow-secret
                      "private key material in staged diff")
    end

    def test_blocks_aws_access_key_id
      assert_blocked("conf.txt", "AWS_KEY=AKIAABCDEFGHIJKLMNOP\n", "AWS access key id in staged diff") # robur:allow-secret
    end

    def test_blocks_sk_style_api_key
      assert_blocked("conf.txt", "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx\n", # robur:allow-secret
                      "API key (sk-/sk-ant-) in staged diff")
    end

    def test_blocks_jwt
      header = "eyJhbGciOiJIUzI1NiJ9"
      payload = "eyJzdWIiOiIxMjM0NTY3ODkwIn0"
      sig = "SflKxwRJSMeKKF2QT4fwpMeJf36POk6y"
      assert_blocked("conf.txt", "Authorization: Bearer #{header}.#{payload}.#{sig}\n", "JWT in staged diff") # robur:allow-secret
    end

    def test_blocks_dot_env_addition
      dir = git_repo
      File.write(File.join(dir, ".env"), "SECRET=1\n")
      result = gate(dir).run(turn: 1, model: "m")
      refute result.committed
      assert_equal ".env file staged", result.block_reason
    end

    def test_allow_secret_marker_exempts_a_line
      dir = git_repo
      File.write(File.join(dir, "conf.txt"),
                 "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx # #{CommitGate::ALLOW_MARKER}\n")
      result = gate(dir).run(turn: 1, model: "m")
      assert result.committed
    end

    # Backward compatibility: suppressions written before the rename are
    # sitting in real repos as `ratchet:allow-secret`. They must keep
    # exempting their line, or the gate starts blocking commits it used to let
    # through.
    def test_legacy_allow_secret_marker_still_exempts_a_line
      dir = git_repo
      File.write(File.join(dir, "conf.txt"),
                 "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx # #{CommitGate::LEGACY_ALLOW_MARKER}\n")
      result = gate(dir).run(turn: 1, model: "m")
      assert result.committed
    end

    def test_commit_each_turn_off_skips_cleanly
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      result = gate(dir, config("COMMIT_EACH_TURN" => "0")).run(turn: 1, model: "m")
      refute result.committed
      assert_nil result.block_reason
      out, = Open3.capture3("git", "-C", dir, "diff", "--cached", "--name-only")
      assert_equal "", out
    end

    # The repo conf is the loop's own contract with the human: a turn must
    # never sneak an edit to it into a commit. Both spellings are unstaged,
    # since an un-migrated repo still has only the legacy file.
    def test_unstages_the_repo_conf_under_either_name
      [Paths::REPO_CONF, Paths::LEGACY_REPO_CONF].each do |conf|
        dir = git_repo
        File.write(File.join(dir, conf), "VERIFY_CMD=true\n")
        File.write(File.join(dir, "new.txt"), "hello\n")
        gate(dir).run(turn: 1, model: "m")
        out, = Open3.capture3("git", "-C", dir, "log", "--format=", "-1", "--name-only")

        refute_includes out, conf
      end
    end

    # Recording proc for the VERIFY_CMD seam: records each command run,
    # returns a green capture by default.
    def spy_proc(runs, out: "", ok: true)
      status = Object.new
      status.define_singleton_method(:success?) { ok }
      spy = Object.new
      spy.define_singleton_method(:spawn_with_deadline) do |cmd, deadline:, **opts|
        runs << [cmd, deadline, opts]
        [out, "", status]
      end
      spy
    end

    def test_verify_not_run_when_nothing_staged
      dir = git_repo
      runs = []
      gate = CommitGate.new(dir, plan: fake_plan, config: config, proc: spy_proc(runs))
      result = gate.run(turn: 1, model: "m")
      refute result.committed
      assert_nil result.block_reason
      assert_empty runs
    end

    def test_verify_runs_when_something_staged
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      runs = []
      gate = CommitGate.new(dir, plan: fake_plan, config: config, proc: spy_proc(runs))
      assert gate.run(turn: 1, model: "m").committed
      assert_equal [["true", 600, { chdir: dir }]], runs
    end

    def test_zero_task_staged_tracker_blocks
      dir = git_repo
      File.write(File.join(dir, "PLAN.md"), "# Plan\n[IN PROGRESS] T1 (normal) bracket dropped\n")
      zero = fake_plan
      zero.define_singleton_method(:counts) { { open: 0, in_progress: 0, done: 0 } }
      lines = []
      result = CommitGate.new(dir, plan: zero, config: config, emit: ->(m) { lines << m }).run(turn: 1, model: "m")
      refute result.committed
      assert_equal "tracker parsed to zero tasks", result.block_reason
      assert lines.any? { |l| l.include?("BLOCKED: tracker parsed to zero tasks") }
      out, = Open3.capture3("git", "-C", dir, "diff", "--cached", "--name-only")
      assert_equal "PLAN.md\n", out
    end

    def test_staged_tracker_with_tasks_does_not_block
      dir = git_repo
      File.write(File.join(dir, "PLAN.md"), "# Plan\n- [ ] T1 (normal) work\n")
      live = fake_plan
      live.define_singleton_method(:counts) { { open: 1, in_progress: 0, done: 0 } }
      assert CommitGate.new(dir, plan: live, config: config).run(turn: 1, model: "m").committed
    end

    def test_unrelated_staged_file_never_triggers_tracker_check
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      zero = fake_plan
      zero.define_singleton_method(:counts) { { open: 0, in_progress: 0, done: 0 } }
      assert CommitGate.new(dir, plan: zero, config: config).run(turn: 1, model: "m").committed
    end

    def test_last_verify_out_gets_full_output_when_loop_log_set
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      runs = []
      gate = CommitGate.new(dir, plan: fake_plan, config: config,
                            proc: spy_proc(runs, out: "verify says ok\n"),
                            loop_log: File.join(dir, "loop.log"))
      assert gate.run(turn: 1, model: "m").committed
      assert_equal "verify says ok\n", File.read(File.join(dir, "last_verify.out"))
    end

    private

    def assert_blocked(filename, content, reason)
      dir = git_repo
      File.write(File.join(dir, filename), content)
      result = gate(dir).run(turn: 1, model: "m")
      refute result.committed
      assert_equal reason, result.block_reason
    end
  end
end
