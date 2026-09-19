# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/gate"
require "robur/state"
require "tmpdir"
require "fileutils"

class FleetGateTest < Minitest::Test
  def setup
    @repo = Dir.mktmpdir("robur-gate")
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  # T1.5: a real on-disk repo layout, not a stub. Writes .robur.conf, a
  # PLAN.md with a class marker and a mix of `[ ]`, `[IN PROGRESS]`,
  # `[HUMAN]` and `[x]` lines, plus optional `.robur/` state files
  # (stop_reason:, last_task: [id, status], backoff: [count, until_epoch]).
  # Every Gate reader below is driven against this fixture.
  def with_repo(open: 1, in_progress: 0, marker: "MACHINE", tracker: "PLAN.md", **state)
    conf = "VERIFY_CMD=true\n"
    conf += "TRACKER_FILE=#{tracker}\n" unless tracker == "PLAN.md"
    File.write(File.join(@repo, ".robur.conf"), conf)

    lines = ["# PLAN"]
    lines.unshift("<!-- class: #{marker} -->") if marker
    (1..open).each { |i| lines << "- [ ] T#{i} open task #{i}" }
    (1..in_progress).each { |i| lines << "- [IN PROGRESS] W#{i} wip task #{i}" }
    lines << "- [HUMAN] H1 parked on a human answer"
    lines << "- [x] D1 done task"
    File.write(File.join(@repo, tracker), lines.join("\n").concat("\n"))

    Robur::State.write_stop_reason(@repo, state[:stop_reason]) if state[:stop_reason]
    Robur::State.write_last_task(@repo, *state[:last_task]) if state[:last_task]
    Robur::State.write_loop_backoff(@repo, *state[:backoff]) if state[:backoff]
    Robur::Fleet::Gate.new(@repo)
  end

  def test_initialized_when_repo_conf_exists
    assert with_repo.initialized?
  end

  def test_not_initialized_without_repo_conf
    refute Robur::Fleet::Gate.new(@repo).initialized?
  end

  def test_open_tasks_counts_open_plus_in_progress
    assert_equal 3, with_repo(open: 2, in_progress: 1).open_tasks
  end

  # The acceptance case, verbatim: 1 open + 1 IN PROGRESS -> 2.
  def test_open_tasks_on_the_acceptance_fixture
    assert_equal 2, with_repo(open: 1, in_progress: 1).open_tasks
  end

  # A repo that renamed its tracker must be counted through the conf, not a
  # hardcoded PLAN.md — the wrong-file read this whole fixture exists to catch.
  def test_repo_whose_tracker_is_not_plan_md_is_still_counted
    assert_equal 2, with_repo(open: 1, in_progress: 1, tracker: "TRACKER.md").open_tasks
  end

  def test_missing_tracker_counts_zero_not_raise
    gate = with_repo
    File.delete(File.join(@repo, "PLAN.md"))
    assert_equal 0, gate.open_tasks
  end

  def test_human_blocked_when_task_still_open
    gate = with_repo(stop_reason: "human_blocked", last_task: ["T1", "running"])
    assert gate.human_blocked?
  end

  def test_human_blocked_when_task_in_progress
    gate = with_repo(in_progress: 1, stop_reason: "human_blocked", last_task: ["W1", "running"])
    assert gate.human_blocked?
  end

  def test_not_human_blocked_when_task_parked
    gate = with_repo(stop_reason: "human_blocked", last_task: ["H1", "running"])
    refute gate.human_blocked?
  end

  def test_not_human_blocked_when_task_done
    gate = with_repo(stop_reason: "human_blocked", last_task: ["D1", "running"])
    refute gate.human_blocked?
  end

  def test_human_blocked_still_true_with_missing_or_unknown_task_id
    gate = with_repo(stop_reason: "human_blocked", last_task: ["?", "running"])
    assert gate.human_blocked?
    File.delete(File.join(@repo, ".robur", "last_task.state"))
    assert gate.human_blocked?
  end

  def test_not_human_blocked_when_stop_reason_differs
    gate = with_repo(stop_reason: "gate_red", last_task: ["T1", "running"])
    refute gate.human_blocked?
  end

  def test_human_class_gated_until_approved
    gate = with_repo(marker: "HUMAN")
    assert gate.class_gated?
    FileUtils.mkdir_p(File.join(@repo, ".robur"))
    FileUtils.touch(File.join(@repo, ".robur", "plan-approved"))
    refute gate.class_gated?
  end

  def test_machine_class_not_gated
    refute with_repo(marker: "MACHINE").class_gated?
  end

  # T2.2: the per-repo autoplan rate limit reads the stamp's mtime. No
  # stamp = due (never planned); 1h-old with the 6h default = not due;
  # 7h-old = due. Verbatim from the acceptance case.
  def test_autoplan_due_reads_stamp_mtime_per_repo
    gate = with_repo(open: 0)
    now = Time.at(1_000_000_000)
    assert gate.autoplan_due?(21_600, now), "missing stamp is due"
    stamp = Robur::State.state_path(@repo, "autoplan.stamp")
    Robur::State.write_raw(@repo, "autoplan.stamp", "")
    File.utime(now - 3600, now - 3600, stamp)
    refute gate.autoplan_due?(21_600, now), "1h-old stamp is not due at 6h"
    File.utime(now - 7 * 3600, now - 7 * 3600, stamp)
    assert gate.autoplan_due?(21_600, now), "7h-old stamp is due"
  end

  def test_no_class_marker_not_gated
    refute with_repo(marker: nil).class_gated?
  end

  def test_verdict_runnable_when_nothing_blocks
    assert_equal :runnable, with_repo.verdict
  end

  def test_verdict_no_conf_when_not_initialized
    assert_equal :no_conf, Robur::Fleet::Gate.new(@repo).verdict
  end

  def test_verdict_caught_up_when_no_open_tasks
    assert_equal :caught_up, with_repo(open: 0).verdict
  end

  def test_verdict_backoff_when_backoff_active
    gate = with_repo(backoff: [1, Time.now.to_i + 3600])
    assert_equal :backoff, gate.verdict
  end

  def test_verdict_human_block_when_waiting_on_human
    gate = with_repo(stop_reason: "human_blocked", last_task: ["T1", "running"])
    assert_equal :human_block, gate.verdict
  end

  def test_verdict_class_gate_when_human_plan_unapproved
    assert_equal :class_gate, with_repo(marker: "HUMAN").verdict
  end

  # Order is the point: backoff expires on its own, an approval does not.
  def test_verdict_backoff_beats_class_gate
    gate = with_repo(marker: "HUMAN", backoff: [1, Time.now.to_i + 3600])
    assert_equal :backoff, gate.verdict
  end

  # :caught_up is the autoplan-eligible verdict, so reading it while a
  # backoff is active buys a failing repo an unattended plan turn every
  # window instead of the silence it was sent to.
  def test_verdict_backoff_beats_caught_up
    gate = with_repo(open: 0, backoff: [1, Time.now.to_i + 3600])
    assert_equal 0, gate.open_tasks
    assert_equal :backoff, gate.verdict
  end

  def test_stop_reason_from_state_when_present
    assert_equal "gate_red", with_repo(stop_reason: "gate_red").stop_reason
  end

  def test_stop_reason_falls_back_by_open_tasks
    assert_equal "stopped", with_repo.stop_reason
    assert_equal "done", with_repo(open: 0).stop_reason
  end
end
