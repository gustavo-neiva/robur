# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/gate"
require "tmpdir"
require "fileutils"

class FleetGateTest < Minitest::Test
  def setup
    @repo = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  def init_repo(tracker: "PLAN.md", conf: "VERIFY_CMD=true\n")
    File.write(File.join(@repo, ".robur.conf"), conf)
    File.write(File.join(@repo, tracker), <<~PLAN)
      <!-- class: MACHINE -->
      # PLAN
      - [ ] T1 one
      - [ ] T2 two
      - [IN PROGRESS] T3 three
      - [x] T4 four
    PLAN
  end

  def gate = Robur::Fleet::Gate.new(@repo)

  def test_initialized_when_repo_conf_exists
    init_repo
    assert gate.initialized?
  end

  def test_not_initialized_without_repo_conf
    refute gate.initialized?
  end

  def test_open_tasks_counts_open_plus_in_progress
    init_repo
    assert_equal 3, gate.open_tasks
  end

  def test_repo_whose_tracker_is_not_plan_md_is_still_counted
    init_repo(tracker: "TRACKER.md", conf: "VERIFY_CMD=true\nTRACKER_FILE=TRACKER.md\n")
    assert_equal 3, gate.open_tasks
  end

  def test_missing_tracker_counts_zero_not_raise
    File.write(File.join(@repo, ".robur.conf"), "VERIFY_CMD=true\n")
    assert_equal 0, gate.open_tasks
  end

  def human_blocked_tracker(checkbox)
    init_repo
    File.write(File.join(@repo, "PLAN.md"), <<~PLAN)
      <!-- class: MACHINE -->
      # PLAN
      - [#{checkbox}] T3.1 ask the human something
    PLAN
    Robur::State.write_stop_reason(@repo, "human_blocked")
    Robur::State.write_last_task(@repo, "T3.1", "running")
  end

  def test_human_blocked_when_task_still_open
    human_blocked_tracker(" ")
    assert gate.human_blocked?
  end

  def test_human_blocked_when_task_in_progress
    human_blocked_tracker("IN PROGRESS")
    assert gate.human_blocked?
  end

  def test_not_human_blocked_when_task_parked
    human_blocked_tracker("HUMAN")
    refute gate.human_blocked?
  end

  def test_not_human_blocked_when_task_done
    human_blocked_tracker("x")
    refute gate.human_blocked?
  end

  def test_human_blocked_still_true_with_missing_or_unknown_task_id
    human_blocked_tracker(" ")
    Robur::State.write_last_task(@repo, "?", "running")
    assert gate.human_blocked?
    File.delete(File.join(@repo, ".robur", "last_task.state"))
    assert gate.human_blocked?
  end

  def test_not_human_blocked_when_stop_reason_differs
    human_blocked_tracker(" ")
    Robur::State.write_stop_reason(@repo, "gate_red")
    refute gate.human_blocked?
  end

  def human_tracker
    init_repo
    File.write(File.join(@repo, "PLAN.md"), "<!-- class: HUMAN -->\n# PLAN\n- [ ] T1 one\n")
  end

  def test_human_class_gated_until_approved
    human_tracker
    assert gate.class_gated?
    FileUtils.mkdir_p(File.join(@repo, ".robur"))
    FileUtils.touch(File.join(@repo, ".robur", "plan-approved"))
    refute gate.class_gated?
  end

  def test_machine_class_not_gated
    init_repo
    refute gate.class_gated?
  end

  def test_no_class_marker_not_gated
    init_repo
    File.write(File.join(@repo, "PLAN.md"), "# PLAN\n- [ ] T1 one\n")
    refute gate.class_gated?
  end

  def verdict_repo(backoff: false)
    init_repo
    Robur::State.write_loop_backoff(@repo, 1, Time.now.to_i + 3600) if backoff
  end

  def test_verdict_runnable_when_nothing_blocks
    verdict_repo
    assert_equal :runnable, gate.verdict
  end

  def test_verdict_no_conf_when_not_initialized
    assert_equal :no_conf, Robur::Fleet::Gate.new(@repo).verdict
  end

  def test_verdict_caught_up_when_no_open_tasks
    verdict_repo
    File.write(File.join(@repo, "PLAN.md"), "<!-- class: MACHINE -->\n- [x] a\n")
    assert_equal :caught_up, gate.verdict
  end

  def test_verdict_backoff_when_backoff_active
    verdict_repo(backoff: true)
    assert_equal :backoff, gate.verdict
  end

  def test_verdict_human_block_when_waiting_on_human
    verdict_repo
    human_blocked_tracker(" ")
    assert_equal :human_block, gate.verdict
  end

  def test_verdict_class_gate_when_human_plan_unapproved
    verdict_repo
    human_tracker
    assert_equal :class_gate, gate.verdict
  end

  # Order is the point: backoff expires on its own, an approval does not.
  def test_verdict_backoff_beats_class_gate
    verdict_repo(backoff: true)
    human_tracker
    assert_equal :backoff, gate.verdict
  end

  def test_stop_reason_from_state_when_present
    verdict_repo
    Robur::State.write_stop_reason(@repo, "gate_red")
    assert_equal "gate_red", gate.stop_reason
  end

  def test_stop_reason_falls_back_by_open_tasks
    verdict_repo
    assert_equal "stopped", gate.stop_reason
    File.write(File.join(@repo, "PLAN.md"), "<!-- class: MACHINE -->\n- [x] a\n")
    assert_equal "done", gate.stop_reason
  end
end
