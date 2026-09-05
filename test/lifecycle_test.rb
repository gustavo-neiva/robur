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

  def test_stop_drain_means_drain
    Dir.mktmpdir do |d|
      Robur::State.write_stop(d, "drain")
      lc = Robur::Lifecycle.new(d)
      assert_equal 1, lc.level
      assert lc.stop_requested?
      refute lc.abort?
    end
  end
end
