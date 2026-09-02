# frozen_string_literal: true

require "test_helper"
require "robur/loop"
require "robur/state"
require "tmpdir"

module Robur
  # wait_for_merge / open_milestone_pr (bin/ratchet:203,261) — mirrors bash
  # selftest suite 29's seven wait_for_merge scenarios: MERGED, CLOSED,
  # timeout, no-gh, no-origin, PARALLEL=1, PARALLEL=0.
  class PrFlowTest < Minitest::Test
    Status = Struct.new(:success?)

    class FakeRepo
      attr_reader :checkout_calls, :checkout_b_calls, :pull_calls, :push_calls

      attr_reader :add_calls, :commit_calls

      def initialize(remote: true, default_branch: "main", checkout_ok: true, checkout_b_ok: true, pull_ok: true,
                     current_branch: "milestone-branch", push_ok: true, diffstat: "", shortstat: "",
                     diff: "", staged: [], commit_ok: true)
        @remote = remote
        @default_branch = default_branch
        @checkout_ok = checkout_ok
        @checkout_b_ok = checkout_b_ok
        @pull_ok = pull_ok
        @current_branch = current_branch
        @push_ok = push_ok
        @diffstat = diffstat
        @shortstat = shortstat
        @diff = diff
        @staged = staged
        @commit_ok = commit_ok
        @checkout_calls = []
        @checkout_b_calls = []
        @pull_calls = 0
        @push_calls = []
        @add_calls = []
        @commit_calls = []
      end

      def remote?(_name = "origin") = @remote
      def default_branch = @default_branch

      def checkout(branch)
        @checkout_calls << branch
        @checkout_ok
      end

      def checkout_b(branch, base)
        @checkout_b_calls << [branch, base]
        @checkout_b_ok
      end

      def pull_ff_only
        @pull_calls += 1
        @pull_ok
      end

      def current_branch = @current_branch

      def push(*args)
        @push_calls << args
        @push_ok
      end

      def diffstat(_range) = @diffstat
      def shortstat(_range) = @shortstat
      def diff(_range, _pathspec = nil) = @diff
      def staged_files = @staged

      def add(pathspec)
        @add_calls << pathspec
      end

      def commit(subject, _body = nil)
        @commit_calls << subject
        @commit_ok
      end
    end

    # Sequenced `gh pr view ... -q .state` responses, then a fixed
    # `gh pr create` result. `states: [nil]` simulates the -q form failing
    # (falls back to plain --json state, which also fails here).
    class FakeGh
      attr_reader :calls

      def initialize(states: [], create_ok: true)
        @states = states.dup
        @last = nil
        @create_ok = create_ok
        @calls = []
      end

      def capture(*cmd, **_opts)
        @calls << cmd
        if cmd[0] == "gh" && cmd[2] == "view"
          state = @states.empty? ? @last : @states.shift
          @last = state
          [state.to_s, "", Status.new(!state.nil?)]
        elsif cmd[0] == "gh" && cmd[2] == "create"
          ["", "", Status.new(@create_ok)]
        else
          ["", "", Status.new(false)]
        end
      end
    end

    def setup
      @log_dir = Dir.mktmpdir
      @loop_log = File.join(@log_dir, "loop.log")
      Robur::CLI.instance_variable_set(:@loop_log, @loop_log)
      Robur::CLI.instance_variable_set(:@quiet, nil)
      @gh_bin = Dir.mktmpdir
      File.write(File.join(@gh_bin, "gh"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, File.join(@gh_bin, "gh"))
      @old_path = ENV["PATH"]
    end

    def teardown
      ENV["PATH"] = @old_path
      Robur::CLI.instance_variable_set(:@loop_log, nil)
      Robur::CLI.instance_variable_set(:@quiet, nil)
      FileUtils.remove_entry(@log_dir)
      FileUtils.remove_entry(@gh_bin)
    end

    def with_gh_on_path
      ENV["PATH"] = "#{@gh_bin}:#{@old_path}"
    end

    def log_lines
      File.readlines(@loop_log, chomp: true)
    end

    # --- wait_for_merge ------------------------------------------------------

    def test_wait_for_merge_merged_checks_out_default_and_pulls
      with_gh_on_path
      repo = FakeRepo.new
      sys = FakeGh.new(states: %w[OPEN MERGED])
      rc = Loop.wait_for_merge("feature-branch", "/repo", { "PARALLEL" => "0" },
                                repo: repo, sys: sys, sleep_it: ->(_s) {})
      assert_equal 0, rc
      assert_equal ["main"], repo.checkout_calls
      assert_equal 1, repo.pull_calls
      assert(log_lines.any? { |l| l.include?("merge-wait | pr=feature-branch | state=OPEN") })
      assert(log_lines.any? { |l| l.include?("merge-wait | pr=feature-branch | state=MERGED") })
    end

    def test_wait_for_merge_closed_returns_1_and_notifies
      with_gh_on_path
      repo = FakeRepo.new
      sys = FakeGh.new(states: %w[CLOSED])
      rc = Loop.wait_for_merge("closed-branch", "/repo", {}, repo: repo, sys: sys, sleep_it: ->(_s) {})
      assert_equal 1, rc
      assert(log_lines.any? { |l| l.include?("HUMAN NEEDED") })
    end

    def test_wait_for_merge_timeout_returns_3
      with_gh_on_path
      repo = FakeRepo.new
      sys = FakeGh.new(states: %w[OPEN])
      rc = Loop.wait_for_merge("timeout-branch", "/repo", { "MERGE_POLL_SECS" => "1", "MERGE_WAIT_TIMEOUT" => "1" },
                                repo: repo, sys: sys, sleep_it: ->(_s) {})
      assert_equal 3, rc
      assert(log_lines.any? { |l| l.include?("HUMAN NEEDED") })
      assert(log_lines.any? { |l| l.include?("merge-wait timeout") })
    end

    def test_wait_for_merge_no_gh_returns_2_manual_mode
      ENV["PATH"] = "/nonexistent-bin-only"
      repo = FakeRepo.new
      rc = Loop.wait_for_merge("no-gh", "/repo", {}, repo: repo, sys: FakeGh.new, sleep_it: ->(_s) {})
      assert_equal 2, rc
      assert(log_lines.any? { |l| l.include?("HUMAN NEEDED") && l.include?("gh not found") })
    end

    def test_wait_for_merge_no_origin_returns_2_manual_mode
      with_gh_on_path
      repo = FakeRepo.new(remote: false)
      rc = Loop.wait_for_merge("no-origin", "/repo", {}, repo: repo, sys: FakeGh.new, sleep_it: ->(_s) {})
      assert_equal 2, rc
      assert(log_lines.any? { |l| l.include?("HUMAN NEEDED") && l.include?("no origin") })
    end

    def test_wait_for_merge_parallel_stays_on_branch_no_checkout_or_pull
      with_gh_on_path
      repo = FakeRepo.new
      sys = FakeGh.new(states: %w[OPEN MERGED])
      rc = Loop.wait_for_merge("milestone-branch", "/repo", { "PARALLEL" => "1" },
                                repo: repo, sys: sys, sleep_it: ->(_s) {})
      assert_equal 0, rc
      assert_empty repo.checkout_calls
      assert_equal 0, repo.pull_calls
    end

    def test_wait_for_merge_gh_pr_view_failure_returns_2
      with_gh_on_path
      repo = FakeRepo.new
      sys = FakeGh.new(states: [nil])
      rc = Loop.wait_for_merge("bad-branch", "/repo", {}, repo: repo, sys: sys, sleep_it: ->(_s) {})
      assert_equal 2, rc
      assert(log_lines.any? { |l| l.include?("HUMAN NEEDED") && l.include?("gh pr view failed") })
    end

    # --- open_milestone_pr ----------------------------------------------------

    def test_open_milestone_pr_push_failure_returns_1
      repo = FakeRepo.new(push_ok: false)
      plan = Plan.new("/nonexistent/PLAN.md")
      rc = Loop.open_milestone_pr("M1", "abc123", "/repo", {}, plan, @loop_log, repo: repo, sys: FakeGh.new)
      assert_equal 1, rc
      assert(log_lines.any? { |l| l.include?("git push failed") })
    end

    def test_open_milestone_pr_no_gh_leaves_branch_for_manual_pr
      ENV["PATH"] = "/nonexistent-bin-only"
      repo = FakeRepo.new
      plan = Plan.new("/nonexistent/PLAN.md")
      rc = Loop.open_milestone_pr("M1", "abc123", "/repo", {}, plan, @loop_log, repo: repo, sys: FakeGh.new)
      assert_equal 2, rc
      assert(log_lines.any? { |l| l.include?("no gh / no origin") })
    end

    def test_open_milestone_pr_success_pushes_creates_pr_and_waits_for_merge
      with_gh_on_path
      repo = FakeRepo.new(diffstat: " 1 file changed, 2 insertions(+)", shortstat: " 1 file changed, 2 insertions(+)")
      sys = FakeGh.new(states: %w[MERGED], create_ok: true)
      conf = { "PR_SOFT_MAX_LINES" => "400", "PARALLEL" => "0" }
      plan = Plan.new("/nonexistent/PLAN.md")
      rc = Loop.open_milestone_pr("M1", "abc123", "/repo", conf, plan, @loop_log,
                                  repo: repo, sys: sys, sleep_it: ->(_s) {})
      assert_equal 0, rc
      assert_equal [[]], repo.push_calls
      assert(log_lines.any? { |l| l.include?("pushed.") })
      assert(log_lines.any? { |l| l.include?("PR opened.") })
    end

    def test_open_milestone_pr_create_failure_returns_1
      with_gh_on_path
      repo = FakeRepo.new
      sys = FakeGh.new(create_ok: false)
      plan = Plan.new("/nonexistent/PLAN.md")
      rc = Loop.open_milestone_pr("M1", "abc123", "/repo", { "PR_SOFT_MAX_LINES" => "400" }, plan, @loop_log,
                                  repo: repo, sys: sys)
      assert_equal 1, rc
      assert(log_lines.any? { |l| l.include?("gh pr create failed") })
    end

    # --- shortstat_changed_lines / milestone_completed_list -------------------

    def test_shortstat_changed_lines_insertions_and_deletions
      assert_equal 12, Loop.shortstat_changed_lines(" 3 files changed, 10 insertions(+), 2 deletions(-)")
    end

    def test_shortstat_changed_lines_insertions_only
      assert_equal 1, Loop.shortstat_changed_lines(" 1 file changed, 1 insertion(+)")
    end

    # --- milestone_branch_lifecycle ---------------------------------------
    # Mirrors bash selftest suite 32's three simulated scenarios.

    def git_repo
      dir = Dir.mktmpdir
      system("git", "-C", dir, "init", "-q", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "config", "user.email", "t@example.com", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "config", "user.name", "T", out: File::NULL, err: File::NULL)
      dir
    end

    def git(dir, *args) = system("git", "-C", dir, *args, out: File::NULL, err: File::NULL)

    def test_milestone_branch_lifecycle_creates_branch_and_milestone_cur
      dir = git_repo
      File.write(File.join(dir, "PLAN.md"), <<~PLAN)
        # Plan
        ## Milestone 1 — first one
        - [x] T1.1 (normal) done task
        - [IN PROGRESS] T1.2 (normal) current task
        - [ ] T1.3 (trivial) next task

        ## Milestone 2 — second one
        - [ ] T2.1 (normal) future task
      PLAN
      git(dir, "add", "PLAN.md")
      git(dir, "commit", "-q", "-m", "init")
      FileUtils.mkdir_p(File.join(dir, ".git", "refs", "remotes", "origin"))
      File.write(File.join(dir, ".git", "refs", "remotes", "origin", "HEAD"), "ref: refs/remotes/origin/main\n")

      plan = Plan.new(File.join(dir, "PLAN.md"))
      Loop.milestone_branch_lifecycle(dir, { "PR_CADENCE" => "milestone" }, plan, repo: Repo.new(dir))

      assert_equal "ratchet/m-milestone-1-first-one", Repo.new(dir).current_branch
      name, base_sha, cycle, errors = State.read_milestone_cur(dir)
      assert_equal "Milestone 1 — first one", name
      refute_empty base_sha
      assert_equal 0, cycle
      assert_equal 0, errors
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_milestone_branch_lifecycle_same_milestone_does_not_recreate_branch
      dir = git_repo
      File.write(File.join(dir, "PLAN.md"), <<~PLAN)
        ## Milestone 1
        - [IN PROGRESS] T1.1 (normal) current
      PLAN
      git(dir, "add", "PLAN.md")
      git(dir, "commit", "-q", "-m", "init")
      base_sha = `git -C #{dir} rev-parse HEAD`.strip
      State.write_milestone_cur(dir, "Milestone 1", base_sha, 0, 0)
      before_branch = Repo.new(dir).current_branch

      plan = Plan.new(File.join(dir, "PLAN.md"))
      Loop.milestone_branch_lifecycle(dir, { "PR_CADENCE" => "milestone" }, plan, repo: Repo.new(dir))

      assert_equal before_branch, Repo.new(dir).current_branch
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_milestone_branch_lifecycle_new_milestone_creates_new_branch
      dir = git_repo
      File.write(File.join(dir, "PLAN.md"), <<~PLAN)
        ## Milestone 1 — first
        - [x] T1.1 (normal) done

        ## Milestone 2 — second
        - [IN PROGRESS] T2.1 (normal) current
      PLAN
      git(dir, "add", "PLAN.md")
      git(dir, "commit", "-q", "-m", "init")
      FileUtils.mkdir_p(File.join(dir, ".git", "refs", "remotes", "origin"))
      File.write(File.join(dir, ".git", "refs", "remotes", "origin", "HEAD"), "ref: refs/remotes/origin/main\n")
      State.write_milestone_cur(dir, "Milestone 1 — first", `git -C #{dir} rev-parse HEAD`.strip, 0, 0)

      plan = Plan.new(File.join(dir, "PLAN.md"))
      Loop.milestone_branch_lifecycle(dir, { "PR_CADENCE" => "milestone" }, plan, repo: Repo.new(dir))

      assert_equal "ratchet/m-milestone-2-second", Repo.new(dir).current_branch
      name, = State.read_milestone_cur(dir)
      assert_equal "Milestone 2 — second", name
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_milestone_branch_lifecycle_noop_when_pr_cadence_not_milestone
      dir = git_repo
      File.write(File.join(dir, "PLAN.md"), "## M1\n- [IN PROGRESS] T1.1 (normal) t\n")
      git(dir, "add", "PLAN.md")
      git(dir, "commit", "-q", "-m", "init")
      before_branch = Repo.new(dir).current_branch

      plan = Plan.new(File.join(dir, "PLAN.md"))
      Loop.milestone_branch_lifecycle(dir, {}, plan, repo: Repo.new(dir))

      assert_equal before_branch, Repo.new(dir).current_branch
      refute File.file?(File.join(dir, ".ratchet", "milestone.cur"))
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    # --- run_review_turn ---------------------------------------------------

    def write_agent_script(dir, name, output)
      path = File.join(dir, name)
      File.write(path, "#!/bin/sh\nprintf '%s' #{output.inspect}\n")
      File.chmod(0o755, path)
      path
    end

    def test_run_review_turn_pass_on_review_pass_token
      dir = git_repo
      agent = write_agent_script(dir, "agent-pass", "REVIEW_PASS")
      conf = { "AGENT_CMD" => agent, "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1" }
      status = Loop.run_review_turn("HEAD", "M1", 0, dir, conf, "", ["fake/model"], File.join(dir, "turn.out"))
      assert_equal "pass", status
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_run_review_turn_fail_on_review_fail_token
      dir = git_repo
      agent = write_agent_script(dir, "agent-fail", "REVIEW_FAIL")
      conf = { "AGENT_CMD" => agent, "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1" }
      status = Loop.run_review_turn("HEAD", "M1", 0, dir, conf, "", ["fake/model"], File.join(dir, "turn.out"))
      assert_equal "fail", status
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_run_review_turn_error_when_no_review_model_available
      dir = git_repo
      status = Loop.run_review_turn("HEAD", "M1", 0, dir, {}, "", [], File.join(dir, "turn.out"))
      assert_equal "error", status
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_run_review_turn_error_on_neither_token
      dir = git_repo
      agent = write_agent_script(dir, "agent-neither", "nothing useful here")
      conf = { "AGENT_CMD" => agent, "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1" }
      status = Loop.run_review_turn("HEAD", "M1", 0, dir, conf, "", ["fake/model"], File.join(dir, "turn.out"))
      assert_equal "error", status
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    # --- milestone_complete_check --------------------------------------------

    def test_milestone_complete_check_nil_without_milestone_cur
      dir = Dir.mktmpdir
      plan = Plan.new(File.join(dir, "PLAN.md"))
      result = Loop.milestone_complete_check(dir, {}, plan, "", [], File.join(dir, "turn.out"), dir, repo: FakeRepo.new)
      assert_nil result
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_milestone_complete_check_nil_when_still_in_same_milestone
      dir = Dir.mktmpdir
      File.write(File.join(dir, "PLAN.md"), "## M1\n- [IN PROGRESS] T1.1 (normal) t\n")
      State.write_milestone_cur(dir, "M1", "abc", 0, 0)
      plan = Plan.new(File.join(dir, "PLAN.md"))
      result = Loop.milestone_complete_check(dir, {}, plan, "", [], File.join(dir, "turn.out"), dir, repo: FakeRepo.new)
      assert_nil result
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_milestone_complete_check_pass_resets_errors_and_opens_pr
      dir = Dir.mktmpdir
      agent = write_agent_script(dir, "agent-pass", "REVIEW_PASS")
      File.write(File.join(dir, "PLAN.md"), "## M1\n- [x] T1.1 done\n\n## M2\n- [IN PROGRESS] T2.1 (normal) t\n")
      State.write_milestone_cur(dir, "M1", "abcd1234", 0, 1)
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new
      sys = FakeGh.new(states: ["MERGED"])
      conf = { "AGENT_CMD" => agent, "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1", "PR_SOFT_MAX_LINES" => "400" }
      with_gh_on_path

      result = Loop.milestone_complete_check(dir, conf, plan, "", ["fake/model"], File.join(dir, "turn.out"), dir,
                                             repo: repo, sys: sys, sleep_it: ->(_s) {})

      assert_nil result
      name, base_sha, cycle, errors = State.read_milestone_cur(dir)
      assert_equal "M1", name
      assert_equal "abcd1234", base_sha
      assert_equal 0, cycle
      assert_equal 0, errors
      assert(log_lines.any? { |l| l.include?("review-pass | m=M1") })
      assert_equal 1, repo.push_calls.length
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_milestone_complete_check_fail_increments_cycle_and_commits_injected_tasks
      dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(dir, ".git")) # commit_review_injected_tasks gates on a real .git dir
      agent = write_agent_script(dir, "agent-fail", "REVIEW_FAIL")
      File.write(File.join(dir, "PLAN.md"), "## M1\n- [x] T1.1 done\n\n## M2\n- [IN PROGRESS] T2.1 (normal) t\n")
      State.write_milestone_cur(dir, "M1", "abcd1234", 0, 0)
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new(staged: ["PLAN.md"])
      conf = { "AGENT_CMD" => agent, "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1", "MAX_REVIEW_CYCLES" => "2" }

      result = Loop.milestone_complete_check(dir, conf, plan, "", ["fake/model"], File.join(dir, "turn.out"), dir, repo: repo)

      assert_nil result
      name, base_sha, cycle, errors = State.read_milestone_cur(dir)
      assert_equal "M1", name
      assert_equal "abcd1234", base_sha
      assert_equal 1, cycle
      assert_equal 0, errors
      assert_equal ["review(ratchet): fix tasks from review cycle 1"], repo.commit_calls
      assert(log_lines.any? { |l| l.include?("review-fail | m=M1 | cycle=1") })
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_milestone_complete_check_fail_stops_at_max_review_cycles
      dir = Dir.mktmpdir
      agent = write_agent_script(dir, "agent-fail", "REVIEW_FAIL")
      File.write(File.join(dir, "PLAN.md"), "## M1\n- [x] T1.1 done\n\n## M2\n- [IN PROGRESS] T2.1 (normal) t\n")
      State.write_milestone_cur(dir, "M1", "abcd1234", 1, 0)
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new
      conf = { "AGENT_CMD" => agent, "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1", "MAX_REVIEW_CYCLES" => "2" }

      result = Loop.milestone_complete_check(dir, conf, plan, "", ["fake/model"], File.join(dir, "turn.out"), dir, repo: repo)

      assert_equal :review_exceeded, result
      assert(log_lines.any? { |l| l.include?("MAX_REVIEW_CYCLES exceeded") })
      assert(log_lines.any? { |l| l.include?("HUMAN NEEDED") })
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_milestone_complete_check_error_twice_proceeds_and_opens_pr
      dir = Dir.mktmpdir
      # no review model AND no flat model -> run_review_turn always returns "error"
      File.write(File.join(dir, "PLAN.md"), "## M1\n- [x] T1.1 done\n\n## M2\n- [IN PROGRESS] T2.1 (normal) t\n")
      State.write_milestone_cur(dir, "M1", "abcd1234", 0, 1)
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new
      sys = FakeGh.new(states: ["MERGED"])
      conf = {}
      with_gh_on_path

      result = Loop.milestone_complete_check(dir, conf, plan, "", [], File.join(dir, "turn.out"), dir,
                                             repo: repo, sys: sys, sleep_it: ->(_s) {})

      assert_nil result
      name, _base_sha, cycle, errors = State.read_milestone_cur(dir)
      assert_equal "M1", name
      assert_equal 0, cycle
      assert_equal 0, errors
      assert(log_lines.any? { |l| l.include?("review turn errors twice") })
      assert_equal 1, repo.push_calls.length
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    # --- auto_plan_pr0 --------------------------------------------------------
    # Mirrors bash selftest suite 31's auto-plan flow.

    def test_auto_plan_pr0_skips_when_pr_cadence_not_milestone
      dir = Dir.mktmpdir
      File.write(File.join(dir, "PLAN.md"), "- [ ] T1 (trivial) task _(placeholder)_\n")
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new
      result = Loop.auto_plan_pr0(dir, {}, plan, File.join(dir, "turn.out"), @loop_log, repo: repo)
      assert_nil result
      assert_empty repo.checkout_b_calls
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_auto_plan_pr0_skips_when_plan_already_ready
      dir = Dir.mktmpdir
      File.write(File.join(dir, "PLAN.md"), "- [ ] T1 (trivial) task\n")
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new
      result = Loop.auto_plan_pr0(dir, { "PR_CADENCE" => "milestone" }, plan, File.join(dir, "turn.out"), @loop_log, repo: repo)
      assert_nil result
      assert_empty repo.checkout_b_calls
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_auto_plan_pr0_dies_when_branch_creation_fails
      dir = Dir.mktmpdir
      File.write(File.join(dir, "PLAN.md"), "- [ ] T1 (trivial) task _(placeholder)_\n")
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new(checkout_b_ok: false)
      assert_raises(SystemExit) do
        Loop.auto_plan_pr0(dir, { "PR_CADENCE" => "milestone" }, plan, File.join(dir, "turn.out"), @loop_log, repo: repo)
      end
      assert(log_lines.any? { |l| l.include?("FATAL: failed to create ratchet/plan branch") })
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_auto_plan_pr0_push_failure_returns_2
      dir = Dir.mktmpdir
      agent = write_agent_script(dir, "agent-plan", "STEP_COMPLETE")
      File.write(File.join(dir, "PLAN.md"), "- [ ] T1 (trivial) task _(placeholder)_\n")
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new(push_ok: false)
      conf = { "PR_CADENCE" => "milestone", "AGENT_CMD" => agent, "MODELS" => "fake/model",
               "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1" }
      result = Loop.auto_plan_pr0(dir, conf, plan, File.join(dir, "turn.out"), @loop_log, repo: repo)
      assert_equal 2, result
      assert(log_lines.any? { |l| l.include?("HUMAN NEEDED") && l.include?("git push failed") })
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_auto_plan_pr0_no_gh_manual_mode_returns_2
      ENV["PATH"] = "/nonexistent-bin-only"
      dir = Dir.mktmpdir
      agent = write_agent_script(dir, "agent-plan", "STEP_COMPLETE")
      File.write(File.join(dir, "PLAN.md"), "- [ ] T1 (trivial) task _(placeholder)_\n")
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new
      conf = { "PR_CADENCE" => "milestone", "AGENT_CMD" => agent, "MODELS" => "fake/model",
               "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1" }
      result = Loop.auto_plan_pr0(dir, conf, plan, File.join(dir, "turn.out"), @loop_log, repo: repo)
      assert_equal 2, result
      assert(log_lines.any? { |l| l.include?("HUMAN NEEDED") && l.include?("no gh/origin") })
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_auto_plan_pr0_gh_pr_create_failure_returns_1
      with_gh_on_path
      dir = Dir.mktmpdir
      agent = write_agent_script(dir, "agent-plan", "STEP_COMPLETE")
      File.write(File.join(dir, "PLAN.md"), "- [ ] T1 (trivial) task _(placeholder)_\n")
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new
      sys = FakeGh.new(create_ok: false)
      conf = { "PR_CADENCE" => "milestone", "AGENT_CMD" => agent, "MODELS" => "fake/model",
               "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1" }
      result = Loop.auto_plan_pr0(dir, conf, plan, File.join(dir, "turn.out"), @loop_log, repo: repo, sys: sys)
      assert_equal 1, result
      assert(log_lines.any? { |l| l.include?("gh pr create failed") })
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_auto_plan_pr0_success_pushes_opens_pr_and_waits_for_merge
      with_gh_on_path
      dir = git_repo
      agent = write_agent_script(dir, "agent-plan", "STEP_COMPLETE")
      File.write(File.join(dir, "PLAN.md"), "- [ ] T1 (trivial) task _(placeholder)_\n")
      git(dir, "add", "PLAN.md")
      git(dir, "commit", "-q", "-m", "init")
      plan = Plan.new(File.join(dir, "PLAN.md"))
      repo = FakeRepo.new
      sys = FakeGh.new(states: ["MERGED"])
      conf = { "PR_CADENCE" => "milestone", "AGENT_CMD" => agent, "MODELS" => "fake/model",
               "TURN_TIMEOUT" => "5", "STALL_TIMEOUT" => "5", "POLL_INTERVAL" => "0.1" }

      result = Loop.auto_plan_pr0(dir, conf, plan, File.join(dir, "turn.out"), @loop_log,
                                  repo: repo, sys: sys, sleep_it: ->(_s) {})

      assert_nil result
      assert_equal [["ratchet/plan", "main"]], repo.checkout_b_calls
      assert(log_lines.any? { |l| l.include?("auto-plan: PR #0 merged, continuing into build loop") })
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_plan_milestone_completed_list
      dir = Dir.mktmpdir
      File.write(File.join(dir, "PLAN.md"), <<~PLAN)
        ## Milestone 1
        - [x] T1.1 (normal) **first** task
        - [x] T1.2 (normal) second task
        - [ ] T1.3 (normal) not done

        ## Milestone 2
        - [x] T2.1 (normal) other milestone
      PLAN
      plan = Plan.new(File.join(dir, "PLAN.md"))
      assert_equal ["[x] T1.1 (normal) first task", "[x] T1.2 (normal) second task"],
                   plan.milestone_completed_list("Milestone 1")
      FileUtils.remove_entry(dir)
    end
  end
end
