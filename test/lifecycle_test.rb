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

  def spawn_lock_holder(pid_path)
    pid = spawn("ruby", "-e",
                "File.open(ARGV[0], File::RDWR|File::CREAT) { |f| f.flock(File::LOCK_EX); f.truncate(0); f.puts(Process.pid); f.flush; sleep 30 }",
                pid_path)
    100.times do
      probe = File.open(pid_path, File::RDWR | File::CREAT)
      held = !probe.flock(File::LOCK_EX | File::LOCK_NB)
      probe.close
      return pid if held
      sleep 0.05
    end
    flunk "lock holder never acquired the lock"
  end

  def test_acquire_lock_returns_false_while_holder_alive
    Dir.mktmpdir do |d|
      pid_path = File.join(d, "loop.pid")
      holder = spawn_lock_holder(pid_path)
      begin
        refute Robur::Lifecycle.new(d).acquire_lock!(pid_path)
        assert_equal holder, File.read(pid_path).to_i
      ensure
        Process.kill("KILL", holder)
        Process.wait(holder)
      end
    end
  end

  def test_acquire_lock_succeeds_after_holder_is_sigkilled
    Dir.mktmpdir do |d|
      pid_path = File.join(d, "loop.pid")
      holder = spawn_lock_holder(pid_path)
      Process.kill("KILL", holder)
      Process.wait(holder)
      lc = Robur::Lifecycle.new(d)
      assert lc.acquire_lock!(pid_path)
      assert_equal Process.pid, File.read(pid_path).to_i
    end
  end
end
