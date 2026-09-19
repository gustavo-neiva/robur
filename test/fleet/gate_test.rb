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
end
