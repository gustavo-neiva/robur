# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"
require "robur/lifecycle"
require "robur/state"

class LifecycleTest < Minitest::Test
  def test_no_stop_file_means_running
    Dir.mktmpdir do |d|
      lc = Robur::Lifecycle.new(d)
      assert_equal 0, lc.level
      refute lc.stop_requested?
      refute lc.abort?
    end
  end

  def test_stop_now_means_abort
    Dir.mktmpdir do |d|
      Robur::State.write_stop(d, "now")
      lc = Robur::Lifecycle.new(d)
      assert_equal 2, lc.level
      assert lc.stop_requested?
      assert lc.abort?
    end
  end

  def test_sleep_returns_interrupted_when_level_rises_after_first_slice
    Dir.mktmpdir do |d|
      lc = Robur::Lifecycle.new(d)
      slices = []
      result = nil
      sleep_it = ->(s) do
        slices << s
        Robur::State.write_stop(d, "drain") if slices.size == 1
      end
      result = lc.sleep(10, sleep_it: sleep_it)
      assert_equal :interrupted, result
      assert_equal [1.0], slices
    end
  end

  def test_sleep_returns_slept_when_level_never_changes
    Dir.mktmpdir do |d|
      lc = Robur::Lifecycle.new(d)
      slices = []
      result = lc.sleep(3, sleep_it: ->(s) { slices << s })
      assert_equal :slept, result
      assert_equal [1.0, 1.0, 1.0], slices
    end
  end

  def test_stop_drain_means_drain
    Dir.mktmpdir do |d|
      Robur::State.write_stop(d, "drain")
      lc = Robur::Lifecycle.new(d)
      assert_equal 1, lc.level
      assert lc.stop_requested?
      refute lc.abort?
    end
  end

  def test_sleep_returns_interrupted_when_level_rises_after_first_slice
    Dir.mktmpdir do |d|
      lc = Robur::Lifecycle.new(d)
      slices = []
      sleep_it = ->(s) {
        slices << s
        Robur::State.write_stop(d, "drain")
      }
      assert_equal :interrupted, lc.sleep(10, sleep_it: sleep_it)
      assert_equal [1.0], slices
    end
  end

  def test_sleep_returns_slept_after_all_slices_when_level_never_changes
    Dir.mktmpdir do |d|
      lc = Robur::Lifecycle.new(d)
      slices = []
      sleep_it = ->(s) { slices << s }
      assert_equal :slept, lc.sleep(3, sleep_it: sleep_it)
      assert_equal [1.0, 1.0, 1.0], slices
    end
  end
end
