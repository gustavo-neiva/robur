# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/cycle"
require "robur/state"
require "tmpdir"
require "fileutils"
require "stringio"

class FleetCycleTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("robur-cycle")
    @repo = make_repo("r")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  # A real on-disk repo: conf + MACHINE tracker with `open` tasks. open: 0
  # reads as caught-up, the autoplan-eligible shape (T2.2).
  def make_repo(name, open: 1)
    dir = File.join(@root, name)
    Dir.mkdir(dir)
    File.write(File.join(dir, ".robur.conf"), "VERIFY_CMD=true\n")
    lines = ["<!-- class: MACHINE -->", "# PLAN"]
    (1..open).each { |i| lines << "- [ ] T#{i} open task #{i}" }
    File.write(File.join(dir, "PLAN.md"), lines.join("\n").concat("\n"))
    dir
  end

  # A real Roster over a real fleet.conf — the one parser, not a stub.
  def roster(*repos)
    conf = File.join(@root, "fleet.conf")
    File.write(conf, repos.join("\n").concat("\n"))
    Robur::Fleet::Roster.new(conf)
  end

  ClockStub = Struct.new(:now)

  def cycle(spawner:, roster: [], notifier: nil, out: $stdout)
    Robur::Fleet::Cycle.new(
      roster: roster,
      gate_for: ->(repo) { Robur::Fleet::Gate.new(repo) },
      budget: Robur::Fleet::Budget.new(max_runs: 4, max_plans: 4,
                                       autoplan_min_secs: 0, backoff_base: 1,
                                       backoff_cap: 2, interval: 3,
                                       healthcheck_url: ""),
      clock: ClockStub.new(Time.at(0)),
      spawner: spawner, notifier: notifier, out: out
    )
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

  private

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
    cyc = cycle(spawner: ->(_a) { 1 }, notifier: notifier)
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
    repos = [@repo, make_repo("r2"), make_repo("r3")]
    cyc = cycle(spawner: ->(_a) { nil })
    results = repos.map { |r| cyc.record_outcome(r, :spawn_error) }
    assert_equal %i[environment environment environment], results
    refute_equal 0, cyc.status
    repos.each { |r| assert_nil Robur::State.read_loop_backoff(r) }
  end

  # --- Cycle#run: the three-phase cycle (T3.4) ---------------------------

  # Acceptance, verbatim: two runnable repos, an injected spawner returning
  # 0 then 1 — both repos were spawned and the exit status is 1. The second
  # run pass skips both (:once_per_cycle), so exactly two spawns happened.
  def test_cycle_runs_both_repos_and_returns_the_last_nonzero_status
    a = make_repo("a")
    b = make_repo("b")
    seen = []
    n = 0
    spawner = lambda do |argv|
      seen << argv.last
      (n += 1) == 1 ? 0 : 1
    end
    assert_equal 1, cycle(spawner: spawner, roster: roster(a, b)).run
    assert_equal [a, b], seen
  end

  # The three phases in order: run pass, plan top-up (`plan --auto`), run
  # pass again. Repo c is caught up in pass one; its plan turn (the injected
  # spawner) ADDS a task, the fresh gates of pass three see it, and c runs —
  # while a and b, already run, are never spawned again. Exactly two run
  # passes: the plan turn could give a third pass nothing new.
  def test_full_cycle_run_plan_run_again_in_order
    a = make_repo("a")
    b = make_repo("b")
    c = make_repo("c", open: 0)
    calls = []
    spawner = lambda do |argv|
      calls << argv[2..]
      if argv[2] == "plan"
        File.write(File.join(argv.last, "PLAN.md"),
                   "<!-- class: MACHINE -->\n# PLAN\n- [ ] T9 planned task\n")
      end
      0
    end
    assert_equal 0, cycle(spawner: spawner, roster: roster(a, b, c)).run
    assert_equal [["run", a], ["run", b], ["plan", "--auto", c], ["run", c]], calls
  end

  # A nil lease logs the holder pid and the repo never spawns — not in pass
  # one, and the lock-skipped set keeps pass three off it too.
  def test_lock_held_repo_is_skipped_without_spawning_for_the_cycle
    a = make_repo("a")
    b = make_repo("b")
    lease = Robur::Fleet::Lock.acquire(b)
    refute_nil lease
    calls = []
    out = StringIO.new
    status = cycle(spawner: ->(argv) { calls << argv.last; 0 },
                   roster: roster(a, b), out: out).run
    assert_equal 0, status
    assert_equal [a], calls
    assert_includes out.string, "lock held by pid #{Process.pid}"
  ensure
    lease&.release
  end

  # --- autoplan stamp (T3.5) ---------------------------------------------

  # Acceptance: a caught-up repo whose plan turn spawned and exited 0
  # producing no tasks — the stamp exists with an advanced mtime and no
  # backoff was recorded: an honest empty plan is not a failure.
  def test_plan_spawn_touches_the_autoplan_stamp_and_records_no_failure
    c = make_repo("c", open: 0)
    stamp = Robur::State.state_path(c, "autoplan.stamp")
    FileUtils.touch(stamp, mtime: Time.at(0))
    out = StringIO.new
    plans = []
    assert_equal 0, cycle(spawner: ->(argv) { plans << argv[2] if argv[2] == "plan"; 0 },
                          roster: roster(c), out: out).run
    assert_equal 1, plans.size # rate limit: exactly one plan turn
    assert File.file?(stamp)
    refute_equal Time.at(0), File.mtime(stamp)
    assert_nil Robur::State.read_loop_backoff(c)
    assert_includes out.string, "no open tasks"
  end

  # Acceptance: a repo skipped for lock contention never spawns, so no
  # stamp is written — stamping a skip would silence its next six hours of
  # planning for work never attempted.
  def test_lock_skipped_repo_gets_no_autoplan_stamp
    c = make_repo("c", open: 0)
    lease = Robur::Fleet::Lock.acquire(c)
    calls = []
    out = StringIO.new
    assert_equal 0, cycle(spawner: ->(argv) { calls << argv.last; 0 },
                          roster: roster(c), out: out).run
    assert_empty calls
    refute File.file?(Robur::State.state_path(c, "autoplan.stamp"))
  ensure
    lease&.release
  end

  # One repo raising must not abort the cycle: the raise is recorded as a
  # failure (cycle status 1) and the next repo still runs.
  def test_a_raising_repo_is_recorded_and_the_cycle_carries_on
    a = make_repo("a")
    b = make_repo("b")
    calls = []
    spawner = lambda do |argv|
      raise "boom" if argv.last == a

      calls << argv.last
      0
    end
    out = StringIO.new
    assert_equal 1, cycle(spawner: spawner, roster: roster(a, b), out: out).run
    assert_equal [b], calls
    assert_includes out.string, "boom"
  end
end

