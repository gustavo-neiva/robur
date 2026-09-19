# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/planner"
require "robur/fleet/roster"

class FleetPlannerTest < Minitest::Test
  # tracker/due feed the T2.2 autoplan path; nil/false tracker or due means
  # no/false (a runnable stub ignores both). tracker?/autoplan_due? mirror
  # the real Gate's query surface; the stamp mtime itself is gate_test's.
  GateStub = Struct.new(:verdict, :tracker, :due) do
    def tracker? = tracker

    def autoplan_due?(_min_secs, _now) = due
  end
  RosterStub = Struct.new(:active)

  def setup
    @runs = 2
    @verdicts = {}
    @roster = RosterStub.new([])
    @env_min_secs = ENV["AUTOPLAN_MIN_SECS"]
    ENV.delete("AUTOPLAN_MIN_SECS")
  end

  def teardown
    ENV["AUTOPLAN_MIN_SECS"] = @env_min_secs
  end

  def planner(already_ran: [], max_runs: @runs, max_plans: 4, now: Time.at(1_000_000_000), paused: false)
    Robur::Fleet::Planner.new(
      roster: @roster,
      gate_for: ->(repo) { @verdicts.fetch(repo) { GateStub.new(:runnable, true, false) } },
      budget: Robur::Fleet::Budget.new(max_runs: max_runs, max_plans: max_plans),
      clock: Struct.new(:now).new(now),
      already_ran: already_ran,
      paused: paused
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
    @verdicts["/r/a"] = GateStub.new(:caught_up, true, true)
    @verdicts["/r/b"] = GateStub.new(:human_block, true, false)
    d = planner(max_runs: 1).decisions
    assert_equal(%i[plan skip run], d.map(&:action))
    assert_equal(%i[caught_up human_block runnable], d.map(&:reason))
  end

  # T2.2: a caught-up repo skips the plan turn while the stamp is fresh.
  # (The mtime arithmetic itself is Gate's — gate_test drives a real stamp.)
  def test_caught_up_not_due_skips_with_autoplan_recent
    active("/r/a")
    @verdicts["/r/a"] = GateStub.new(:caught_up, true, false)
    d = planner.decisions.first
    assert_equal(%i[skip], [d.action])
    assert_equal(:autoplan_recent, d.reason)
  end

  # Acceptance: stamp 7h old (or missing — both read due on Gate) with the
  # 6h default -> the unattended `plan --auto` turn is emitted as :plan.
  def test_caught_up_due_emits_plan
    active("/r/a")
    @verdicts["/r/a"] = GateStub.new(:caught_up, true, true)
    d = planner.decisions.first
    assert_equal(:plan, d.action)
    assert_equal(:caught_up, d.reason)
  end

  def test_caught_up_without_tracker_is_not_planned
    active("/r/a")
    @verdicts["/r/a"] = GateStub.new(:caught_up, false, true)
    d = planner.decisions.first
    assert_equal(%i[skip], [d.action])
    assert_equal(:caught_up, d.reason)
  end

  def test_plans_are_bounded_by_max_plans
    active("/r/a", "/r/b", "/r/c")
    @verdicts["/r/a"] = @verdicts["/r/b"] = @verdicts["/r/c"] =
      GateStub.new(:caught_up, true, true)
    d = planner(max_plans: 2).decisions
    assert_equal(%i[plan plan skip], d.map(&:action))
    assert_equal(%i[caught_up caught_up max_plans], d.map(&:reason))
  end

  # Backed off (likewise human-blocked / class-gated) is never auto-planned,
  # however due the stamp says it is.
  def test_backed_off_repo_is_never_planned
    active("/r/a")
    @verdicts["/r/a"] = GateStub.new(:backoff, true, true)
    d = planner.decisions.first
    assert_equal(%i[skip], [d.action])
    assert_equal(:backoff, d.reason)
  end

  # Global/ENV only: default 21_600, ENV overrides. Never a repo-conf key.
  def test_autoplan_min_secs_defaults_to_21600_and_reads_env
    active("/r/a")
    recorder = Class.new(GateStub) do
      attr_accessor :got_min

      def autoplan_due?(min_secs, _now)
        self.got_min = min_secs
        due
      end
    end
    @verdicts["/r/a"] = g = recorder.new(:caught_up, true, true)
    planner.decisions
    assert_equal 21_600, g.got_min
    ENV["AUTOPLAN_MIN_SECS"] = "60"
    planner.decisions
    assert_equal 60, g.got_min
  end

  # Acceptance: cycle_plan groups that same decision under :plans — a
  # grouping of the ONE #decisions walk, deciding nothing new.
  def test_cycle_plan_groups_runs_and_plans_off_one_walk
    active("/r/a", "/r/b", "/r/c")
    @verdicts["/r/a"] = GateStub.new(:caught_up, true, true)
    @verdicts["/r/b"] = GateStub.new(:backoff, true, true)
    cp = planner(max_runs: 1).cycle_plan
    assert_equal(%i[run], cp[:runs].map(&:action))
    assert_equal(%i[plan], cp[:plans].map(&:action))
    assert_equal(%w[/r/a], cp[:plans].map(&:repo))
  end

  # T2.3: paused -> every active repo skips with :paused and the cycle
  # spends nothing. The caller stats the flag (purity test below enforces
  # the planner never does); dry_run passes Paths.fleet_paused_flag.
  def test_paused_skips_every_active_repo_and_plans_nothing
    active("/r/a", "/r/b")
    p = planner(paused: true)
    d = p.decisions
    assert_equal(%i[skip skip], d.map(&:action))
    assert_equal(%i[paused paused], d.map(&:reason))
    cp = p.cycle_plan
    assert_empty cp[:runs]
    assert_empty cp[:plans]
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
