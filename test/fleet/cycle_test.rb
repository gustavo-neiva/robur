# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/cycle"
require "robur/state"
require "tmpdir"
require "fileutils"

class FleetCycleTest < Minitest::Test
  def setup
    @repo = Dir.mktmpdir("robur-cycle")
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  def cycle(spawner:)
    Robur::Fleet::Cycle.new(planner: nil, spawner: spawner)
  end

  # Acceptance: the exe resolved from the live process is a real,
  # executable file — this is the check that would have caught the
  # launchd/system-Ruby-2.6 outages.
  def test_exe_exists_and_is_executable
    assert File.executable?(Robur::Fleet::Cycle::EXE), Robur::Fleet::Cycle::EXE
  end

  # Acceptance: argv[0] is RbConfig.ruby and argv[1] the existing exe —
  # built in Cycle#spawn, so an injected spawner sees the exact argv with
  # no process launched.
  def test_spawn_builds_command_from_the_live_process
    seen = []
    status = cycle(spawner: ->(argv) { seen << argv; 0 }).spawn(@repo, "run", @repo)
    assert_equal 0, status
    assert_equal [RbConfig.ruby, Robur::Fleet::Cycle::EXE, "run", @repo], seen.first
  end

  # Acceptance: a child that cannot be started yields :spawn_error, not an
  # exit code — nil is reserved for the environment fault (T3.3).
  def test_child_that_never_started_yields_spawn_error
    assert_equal :spawn_error, cycle(spawner: ->(_argv) { nil }).spawn(@repo, "run")
  end

  def test_nonzero_exit_passes_through
    assert_equal 3, cycle(spawner: ->(_argv) { 3 }).spawn(@repo, "run")
  end

  # The DEFAULT spawner's own mapping: system's true/false both carry an
  # exit status, its nil (never started) must stay nil. A real process is
  # launched here, but only `ruby -e exit` — never a turn.
  def test_default_spawner_maps_system_results
    spawner = Robur::Fleet::Cycle::DEFAULT_SPAWNER
    assert_equal 3, spawner.([RbConfig.ruby, "-e", "exit 3"])
    assert_nil spawner.(["/nonexistent/robur-spawn-probe"])
  end

  # --- record_outcome: the policy table (T3.3) ---------------------------

  def spy_notifier
    calls = []
    notifier = Object.new
    notifier.define_singleton_method(:notify_once) { |*args| calls << args }
    [notifier, calls]
  end

  # Acceptance: with stop_reason "done" an existing backoff file is removed.
  def test_done_clears_an_existing_backoff
    Robur::State.write_loop_backoff(@repo, 2, Time.now.to_i + 9_999)
    Robur::State.write_stop_reason(@repo, "done")
    assert_equal :cleared, cycle(spawner: ->(_a) { 0 }).record_outcome(@repo, 0)
    assert_nil Robur::State.read_loop_backoff(@repo)
  end

  # Acceptance: exit 0 + "stopped" — the loop-backoff file is neither
  # created nor modified. A human ran `robur stop`; that is an instruction,
  # not a failure, and backing off for it costs the next beat too.
  def test_stopped_neither_creates_nor_modifies_backoff
    cyc = cycle(spawner: ->(_a) { 0 })
    Robur::State.write_stop_reason(@repo, "stopped")
    assert_equal :no_change, cyc.record_outcome(@repo, 0)
    assert_nil Robur::State.read_loop_backoff(@repo)

    until_epoch = Time.now.to_i + 9_999
    Robur::State.write_loop_backoff(@repo, 1, until_epoch)
    cyc.record_outcome(@repo, 0)
    assert_equal [1, until_epoch], Robur::State.read_loop_backoff(@repo)
  end

  # Acceptance: with stop_reason "gate_red" the backoff count increments by
  # one. The real child exits 1 for gate_red.
  def test_gate_red_bumps_the_ladder_by_one
    cyc = cycle(spawner: ->(_a) { 1 })
    Robur::State.write_stop_reason(@repo, "gate_red")
    assert_equal :bumped, cyc.record_outcome(@repo, 1)
    assert_equal 1, Robur::State.read_loop_backoff(@repo)[0]
    cyc.record_outcome(@repo, 1)
    assert_equal 2, Robur::State.read_loop_backoff(@repo)[0]
  end

  # human_blocked: the repo is skipped for the rest of the cycle and the
  # notifier hook fires (T5.3 wires the real Notifier).
  def test_human_blocked_skips_the_repo_for_the_cycle_and_notifies
    notifier, calls = spy_notifier
    cyc = Robur::Fleet::Cycle.new(planner: nil, spawner: ->(_a) { 1 }, notifier: notifier)
    Robur::State.write_stop_reason(@repo, "human_blocked")
    assert_equal :skipped, cyc.record_outcome(@repo, 1)
    assert_equal [@repo], cyc.human_skipped
    assert_equal 1, calls.size
    assert_equal @repo, calls.first[0]
    assert_equal "human_blocked", calls.first[1]
  end

  def test_progress_stalled_and_review_exceeded_bump
    cyc = cycle(spawner: ->(_a) { 0 })
    Robur::State.write_stop_reason(@repo, "progress_stalled")
    assert_equal :bumped, cyc.record_outcome(@repo, 0)
    assert_equal 1, Robur::State.read_loop_backoff(@repo)[0]
    Robur::State.write_stop_reason(@repo, "review_exceeded")
    assert_equal :bumped, cyc.record_outcome(@repo, 0)
    assert_equal 2, Robur::State.read_loop_backoff(@repo)[0]
  end

  # A real nonzero exit bumps even with NO stop_reason file: Gate's derived
  # fallback ("done"/"stopped") must never turn a crash into a clear or a
  # no-op.
  def test_real_nonzero_exit_bumps_with_no_stop_reason_file
    cyc = cycle(spawner: ->(_a) { 7 })
    assert_equal :bumped, cyc.record_outcome(@repo, 7)
    assert_equal 1, Robur::State.read_loop_backoff(@repo)[0]
  end

  # Acceptance: with :spawn_error across a 3-repo roster no repo's backoff
  # file is touched and the cycle is red — a child that never started is a
  # property of this machine, not of any repo.
  def test_spawn_error_fails_the_cycle_and_backs_off_no_repo
    repos = [@repo, "#{this_dir}/r2", "#{this_dir}/r3"]
    repos[1, 2].each { |r| Dir.mkdir(r) }
    cyc = cycle(spawner: ->(_a) { nil })
    results = repos.map { |r| cyc.record_outcome(r, :spawn_error) }
    assert_equal %i[environment environment environment], results
    refute_equal 0, cyc.status
    repos.each { |r| assert_nil Robur::State.read_loop_backoff(r) }
  ensure
    repos[1, 2].each { |r| FileUtils.remove_entry(r) rescue nil }
  end

  private

  # This test class's tmpdir root — siblings r2/r3 live beside it so the
  # 3-repo roster test needs no second mktmpdir lifecycle.
  def this_dir
    @this_dir ||= File.dirname(@repo)
  end
end
