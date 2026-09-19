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
end
