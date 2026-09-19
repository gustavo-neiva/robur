# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/planner"
require "robur/fleet/roster"

class FleetPlannerTest < Minitest::Test
  GateStub = Struct.new(:verdict)
  RosterStub = Struct.new(:active)

  def setup
    @runs = 2
    @verdicts = {}
    @roster = RosterStub.new([])
  end

  def planner(already_ran: [], max_runs: @runs)
    Robur::Fleet::Planner.new(
      roster: @roster,
      gate_for: ->(repo) { @verdicts.fetch(repo) { GateStub.new(:runnable) } },
      budget: Robur::Fleet::Budget.new(max_runs: max_runs, max_plans: 4),
      clock: Object.new,
      already_ran: already_ran
    )
  end

  def active(*paths)
    @roster.active = paths.map do |p|
      Robur::Fleet::Roster::Entry.new(path: p, parked: false, lineno: 1, raw: p)
    end
  end

  def test_runnable_until_max_runs_spent_then_skip_max_runs
    active("/r/a", "/r/b", "/r/c")
    d = planner(max_runs: 2).decisions
    assert_equal(%i[run run skip], d.map(&:action))
    assert_equal(%i[runnable runnable max_runs], d.map(&:reason))
    assert_equal(%w[/r/a /r/b /r/c], d.map(&:repo))
  end

  def test_already_ran_skips_once_per_cycle_and_spends_no_budget
    active("/r/a", "/r/b")
    d = planner(already_ran: ["/r/a"], max_runs: 2).decisions
    assert_equal(%i[skip run], d.map(&:action))
    assert_equal(%i[once_per_cycle runnable], d.map(&:reason))
  end

  def test_other_verdicts_skip_carrying_the_gate_reason
    active("/r/a", "/r/b", "/r/c")
    @verdicts["/r/a"] = GateStub.new(:caught_up)
    @verdicts["/r/b"] = GateStub.new(:human_block)
    d = planner(max_runs: 1).decisions
    assert_equal(%i[skip skip run], d.map(&:action))
    assert_equal(%i[caught_up human_block runnable], d.map(&:reason))
  end

  def test_decisions_are_keyword_structs
    active("/r/a")
    d = planner.decisions.first
    assert_instance_of Robur::Fleet::Planner::Decision, d
    assert d.repo && d.action && d.reason
  end

  def test_planner_source_is_pure_no_io_clock_or_spawn
    src = File.read(File.expand_path("../../lib/robur/fleet/planner.rb", __dir__))
    refute_match(/File\.|Dir\.|IO\.|Time\.|Process\.|system\(|spawn\(|Kernel\./, src)
  end
end
