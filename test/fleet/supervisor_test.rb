# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet"
require "robur/lifecycle"
require "fileutils"
require "tmpdir"

# T5.1: the supervisor beats forever, rescues a raising cycle, and drains
# without waiting out the interval when a stop lands during the sleep. All
# fakes are injected — no real sleeping, no real signals.
class FleetSupervisorTest < Minitest::Test
  # Raises on call N (nil = never), returns 0 otherwise.
  class StubCycle
    attr_reader :calls

    def initialize(raise_on: nil)
      @calls = 0
      @raise_on = raise_on
    end

    def run
      @calls += 1
      raise "boom" if @calls == @raise_on
      0
    end
  end

  # stop_requested? flips true once @sleeps reaches the threshold; sleep is
  # instant and records the interval it was handed.
  class StubLifecycle
    attr_reader :sleeps, :intervals

    def initialize(stop_after_sleeps: nil)
      @sleeps = 0
      @stop_after = stop_after_sleeps
      @intervals = []
    end

    def stop_requested? = !@stop_after.nil? && @sleeps >= @stop_after
    def install! = self

    def sleep(secs)
      @sleeps += 1
      @intervals << secs
      :slept
    end
  end

  # The acceptance case: first call raises, the supervisor still beats three
  # times, and the raise did not end it.
  def test_raising_cycle_does_not_end_supervisor
    cycle = StubCycle.new(raise_on: 1)
    life = StubLifecycle.new(stop_after_sleeps: 3)
    out, = capture_io do
      assert_equal 0, Robur::Fleet::Supervisor.new(interval: 1, cycle: cycle, lifecycle: life).run
    end
    assert_equal 3, cycle.calls
    assert_equal 3, life.sleeps
    assert_includes out, "boom"
  end

  # A stop that lands during the sleep ends the run WITHOUT a further cycle —
  # and with a huge interval, proves no real wait happened.
  def test_stop_during_sleep_ends_without_another_cycle
    cycle = StubCycle.new
    life = StubLifecycle.new(stop_after_sleeps: 1)
    Robur::Fleet::Supervisor.new(interval: 10_000, cycle: cycle, lifecycle: life).run
    assert_equal 1, cycle.calls
    assert_equal 1, life.sleeps
  end

  # The interval handed to the lifecycle's sleep is the one injected — the
  # supervisor must delegate to the INTERRUPTIBLE sleep, not Kernel.sleep.
  def test_sleep_receives_injected_interval
    life = StubLifecycle.new(stop_after_sleeps: 1)
    Robur::Fleet::Supervisor.new(interval: 42, cycle: StubCycle.new, lifecycle: life).run
    assert_equal [42], life.intervals
  end

  # Without an explicit interval the default is Fleet.budget.interval, so
  # FLEET_INTERVAL (ENV, global-only) governs the beat.
  def test_interval_defaults_to_budget_interval
    ENV["FLEET_INTERVAL"] = "30"
    life = StubLifecycle.new(stop_after_sleeps: 1)
    Robur::Fleet::Supervisor.new(cycle: StubCycle.new, lifecycle: life).run
    assert_equal [30], life.intervals
  ensure
    ENV.delete("FLEET_INTERVAL")
  end

  # "900", "15m", "2h" parse; garbage (including 0, which would busy-loop)
  # raises instead of falling back.
  def test_parse_interval
    assert_equal 900, Robur::Fleet::Supervisor.parse_interval("900")
    assert_equal 900, Robur::Fleet::Supervisor.parse_interval("15m")
    assert_equal 7200, Robur::Fleet::Supervisor.parse_interval("2h")
    assert_raises(ArgumentError) { Robur::Fleet::Supervisor.parse_interval("abc") }
    assert_raises(ArgumentError) { Robur::Fleet::Supervisor.parse_interval("15x") }
    assert_raises(ArgumentError) { Robur::Fleet::Supervisor.parse_interval("0") }
  end

  # Real Lifecycle integration, still no real sleep: a stop file present
  # before the first beat ends the run after exactly one cycle, without the
  # lifecycle ever being slept on (interval is 10_000s).
  def test_real_lifecycle_stop_file_ends_after_one_cycle
    dir = Dir.mktmpdir
    Robur::State.write_stop(dir, "drain")
    cycle = StubCycle.new
    life = Robur::Lifecycle.new(dir).install!
    Robur::Fleet::Supervisor.new(interval: 10_000, cycle: cycle, lifecycle: life).run
    assert_equal 1, cycle.calls
  ensure
    FileUtils.remove_entry(dir)
  end
end
