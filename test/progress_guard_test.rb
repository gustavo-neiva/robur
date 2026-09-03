# frozen_string_literal: true

require_relative "test_helper"
require "robur/progress_guard"

class ProgressGuardTest < Minitest::Test
  def test_committed_keeps_stalls_at_zero_with_unchanged_mtime
    t = Time.at(0)
    guard = Robur::ProgressGuard.new("/no/such", mtime: ->(_p) { t })
    5.times do
      assert_equal :ok, guard.record(committed: true)
    end
    assert_equal 0, guard.stalls
  end

  def test_mtime_change_without_commit_is_progress
    t = Time.at(0)
    guard = Robur::ProgressGuard.new("/no/such", mtime: ->(_p) { t })
    guard.record(committed: false) # baseline
    t = Time.at(100)
    assert_equal :ok, guard.record(committed: false)
    assert_equal 0, guard.stalls
  end

  def test_no_commit_no_mtime_change_increments_stalls
    t = Time.at(0)
    guard = Robur::ProgressGuard.new("/no/such", mtime: ->(_p) { t })
    guard.record(committed: false) # baseline: first mtime is not a change
    guard.record(committed: false)
    assert_equal 2, guard.stalls
  end

  def test_first_record_mtime_is_baseline_not_change
    t = Time.at(0)
    guard = Robur::ProgressGuard.new("/no/such", mtime: ->(_p) { t })
    assert_equal :ok, guard.record(committed: false) # stalls 1, not "progress"
    assert_equal 1, guard.stalls
  end

  def test_thresholds_fire_once_each_and_stop_repeats
    t = Time.at(0)
    guard = Robur::ProgressGuard.new("/no/such", mtime: ->(_p) { t })
    results = Array.new(17) { guard.record(committed: false) }
    assert_equal :ok, results[0]
    assert_equal :ok, results[1]
    assert_equal :bench, results[2]           # stalls 3
    assert_equal :ok, results[3]
    assert_equal :ok, results[4]
    assert_equal :inject_context, results[5]  # stalls 6
    assert_equal :ok, results[6]
    assert_equal :ok, results[7]
    assert_equal :ok, results[8]
    assert_equal :block_task, results[9]      # stalls 10
    assert_equal :ok, results[10]
    assert_equal :ok, results[13]
    assert_equal :stop, results[14]           # stalls 15
    assert_equal :stop, results[15]           # and every record after
    assert_equal :stop, results[16]
    assert_equal 17, guard.stalls
  end

  def test_progress_mid_stall_resets_and_all_thresholds_refire
    t = Time.at(0)
    guard = Robur::ProgressGuard.new("/no/such", mtime: ->(_p) { t })
    3.times { guard.record(committed: false) }
    assert_equal 3, guard.stalls
    t = Time.at(5)
    assert_equal :ok, guard.record(committed: false) # mtime change = progress
    assert_equal 0, guard.stalls
    2.times { guard.record(committed: false) }
    assert_equal :bench, guard.record(committed: false) # fires again this stall-run
    assert_equal 3, guard.stalls
    2.times { guard.record(committed: false) }
    assert_equal :inject_context, guard.record(committed: false) # stalls 6
    3.times { guard.record(committed: false) }
    assert_equal :block_task, guard.record(committed: false) # stalls 10
  end

  def test_nil_mtime_never_raises_and_nil_to_nil_is_not_change
    guard = Robur::ProgressGuard.new("/no/such", mtime: ->(_p) { nil })
    assert_equal :ok, guard.record(committed: false)
    assert_equal :ok, guard.record(committed: false)
    assert_equal :ok, guard.record(committed: true) # committed is still progress
    assert_equal :ok, guard.record(committed: false) # nil→nil not a change
    assert_equal 1, guard.stalls
  end

  def test_custom_threshold_ordering
    t = Time.at(0)
    guard = Robur::ProgressGuard.new("/no/such", block_at: 2, bench_at: 4, mtime: ->(_p) { t })
    assert_equal :ok, guard.record(committed: false)          # stalls 1
    assert_equal :block_task, guard.record(committed: false)  # stalls 2
    assert_equal :ok, guard.record(committed: false)          # stalls 3
    assert_equal :bench, guard.record(committed: false)       # stalls 4
  end

  def test_stop_fires_every_record_at_and_after_stop_at
    t = Time.at(0)
    guard = Robur::ProgressGuard.new("/no/such", stop_at: 2, mtime: ->(_p) { t })
    guard.record(committed: false)
    assert_equal :stop, guard.record(committed: false)
    assert_equal :stop, guard.record(committed: false)
    assert_equal :stop, guard.record(committed: false)
    # progress clears it
    assert_equal :ok, guard.record(committed: true)
    assert_equal 0, guard.stalls
  end

  def test_reset_clears_stalls
    t = Time.at(0)
    guard = Robur::ProgressGuard.new("/no/such", mtime: ->(_p) { t })
    5.times { guard.record(committed: false) }
    guard.reset
    assert_equal 0, guard.stalls
    guard.record(committed: false)
    assert_equal 1, guard.stalls
  end
end
