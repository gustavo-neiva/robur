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
  # Raises on call N (nil = never), otherwise returns exit_status and
  # reports self_updated? (T5.5) — the two things Supervisor reads back.
  class StubCycle
    attr_reader :calls

    def initialize(raise_on: nil, exit_status: 0, self_updated: false)
      @calls = 0
      @raise_on = raise_on
      @exit_status = exit_status
      @self_updated = self_updated
    end

    def run
      @calls += 1
      raise "boom" if @calls == @raise_on
      @exit_status
    end

    def self_updated? = @self_updated
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

  # T5.5: a GREEN cycle whose turn committed to robur's own checkout ends
  # the run immediately — no further sleep, exit 75 for daemon respawn.
  def test_green_self_update_exits_restart_status
    cycle = StubCycle.new(self_updated: true)
    life = StubLifecycle.new(stop_after_sleeps: 99)
    out, = capture_io do
      assert_equal Robur::Fleet::Supervisor::RESTART_EXIT_STATUS,
                   Robur::Fleet::Supervisor.new(interval: 1, cycle: cycle, lifecycle: life).run
    end
    assert_equal 1, cycle.calls
    assert_equal 0, life.sleeps
    assert_includes out, "75"
  end

  # A commit in any OTHER repo never sets self_updated?: the supervisor
  # keeps beating normally and exits 0.
  def test_other_repo_commit_keeps_beating
    cycle = StubCycle.new(self_updated: false)
    life = StubLifecycle.new(stop_after_sleeps: 2)
    assert_equal 0, Robur::Fleet::Supervisor.new(interval: 1, cycle: cycle, lifecycle: life).run
    assert_equal 2, cycle.calls
    assert_equal 2, life.sleeps
  end

  # A RED cycle that touched its own checkout keeps beating — restarting on
  # a failure would just loop the crash.
  def test_red_self_update_keeps_beating
    cycle = StubCycle.new(exit_status: 1, self_updated: true)
    life = StubLifecycle.new(stop_after_sleeps: 2)
    assert_equal 0, Robur::Fleet::Supervisor.new(interval: 1, cycle: cycle, lifecycle: life).run
    assert_equal 2, cycle.calls
    assert_equal 2, life.sleeps
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
