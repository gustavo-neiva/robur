# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/cycle"
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
end
